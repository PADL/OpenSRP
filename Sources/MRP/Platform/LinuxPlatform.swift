//
// Copyright (c) 2024 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#if os(Linux)

import AsyncAlgorithms
@preconcurrency
import AsyncExtensions
import CLinuxSockAddr
import CNetLink
import Glibc
import IORing
import IORingUtils
import NetLink
import SocketAddress
import SystemPackage

private func _makeLinkLayerAddress(
  family: sa_family_t = sa_family_t(AF_PACKET),
  macAddress: EUI48? = nil,
  etherType: UInt16 = UInt16(ETH_P_ALL),
  packetType: UInt8 = UInt8(PACKET_HOST),
  index: Int? = nil
) -> sockaddr_ll {
  var sll = sockaddr_ll()
  sll.sll_family = UInt16(family)
  sll.sll_protocol = etherType.bigEndian
  sll.sll_ifindex = CInt(index ?? 0)
  sll.sll_pkttype = packetType
  sll.sll_halen = UInt8(ETH_ALEN)
  if let macAddress {
    sll.sll_addr.0 = macAddress.0
    sll.sll_addr.1 = macAddress.1
    sll.sll_addr.2 = macAddress.2
    sll.sll_addr.3 = macAddress.3
    sll.sll_addr.4 = macAddress.4
    sll.sll_addr.5 = macAddress.5
  }
  return sll
}

private func _makeLinkLayerAddressBytes(
  family: sa_family_t = sa_family_t(AF_PACKET),
  macAddress: EUI48? = nil,
  etherType: UInt16 = UInt16(ETH_P_ALL),
  packetType: UInt8 = UInt8(PACKET_HOST),
  index: Int? = nil
) -> [UInt8] {
  var sll = _makeLinkLayerAddress(
    family: family,
    macAddress: macAddress,
    etherType: etherType,
    index: index
  )
  return withUnsafeBytes(of: &sll) {
    Array($0)
  }
}

public struct LinuxPort: Port, Sendable, CustomStringConvertible {
  public typealias ID = Int

  public static func == (_ lhs: LinuxPort, _ rhs: LinuxPort) -> Bool {
    lhs.id == rhs.id
  }

  fileprivate let _rtnl: RTNLLink
  fileprivate weak var _bridge: LinuxBridge?

  init(rtnl: RTNLLink, bridge: LinuxBridge) throws {
    _rtnl = rtnl
    _bridge = bridge
  }

  public var description: String {
    "LinuxPort(name: \(name), id: \(id))"
  }

  public func hash(into hasher: inout Hasher) {
    id.hash(into: &hasher)
  }

  public var isOperational: Bool {
    _rtnl.flags & IFF_RUNNING != 0
  }

  public var isEnabled: Bool {
    _rtnl.flags & IFF_UP != 0
  }

  public var isPointToPoint: Bool {
    _rtnl.flags & IFF_POINTOPOINT != 0
  }

  public var _isBridgeSelf: Bool {
    _isBridge && _rtnl.master == _rtnl.index
  }

  public var _isBridge: Bool {
    _rtnl is RTNLLinkBridge
  }

  public var _isVLAN: Bool {
    _rtnl is RTNLLinkVLAN
  }

  public var name: String {
    _rtnl.name
  }

  public var id: Int {
    _rtnl.index
  }

  public var macAddress: EUI48 {
    _rtnl.address
  }

  public var pvid: UInt16? {
    _pvid
  }

  public var vlans: Set<VLAN> {
    guard let vlans = _vlans else { return [] }
    return Set(vlans.map { VLAN(id: $0) })
  }
}

private extension LinuxPort {
  var _vlans: Set<UInt16>? {
    (_rtnl as? RTNLLinkBridge)?.bridgeTaggedVLANs
  }

  var _pvid: UInt16? {
    (_rtnl as? RTNLLinkBridge)?.bridgePVID
  }

  func _add(vlans: Set<VLAN>) async throws {
    try await (_rtnl as! RTNLLinkBridge).add(
      vlans: Set(vlans.map(\.vid)),
      socket: _bridge!._nlLinkSocket
    )
  }

  func _remove(vlans: Set<VLAN>) async throws {
    try await (_rtnl as! RTNLLinkBridge).remove(
      vlans: Set(vlans.map(\.vid)),
      socket: _bridge!._nlLinkSocket
    )
  }
}

public final class LinuxBridge: Bridge, CustomStringConvertible, @unchecked
Sendable {
  public typealias Port = LinuxPort

  private let _txSocket: Socket
  fileprivate let _nlLinkSocket: NLSocket
  private let _nlNfLog: NFNLLog
  private var _nlNfLogMonitorTask: Task<(), Error>!
  private var _nlLinkMonitorTask: Task<(), Error>!
  private let _bridgeName: String
  private var _bridgeIndex: Int = 0
  private var _bridgePort: Port?
  private let _portNotificationChannel = AsyncChannel<PortNotification<Port>>()
  private let _rxPacketsChannel = AsyncThrowingChannel<(Port.ID, IEEE802Packet), Error>()
  private var _linkLocalRegistrations = Set<FilterRegistration>()
  private var _linkLocalRxTasks = [LinkLocalRXTaskKey: Task<(), Error>]()

  public init(name: String, netFilterGroup group: Int) throws {
    _txSocket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_PACKET), type: SOCK_RAW)
    _nlLinkSocket = try NLSocket(protocol: NETLINK_ROUTE)
    _nlNfLog = try NFNLLog(group: UInt16(group))
    _bridgeName = name
  }

  deinit {
    try? _shutdown()
  }

  public nonisolated var description: String {
    "LinuxBridge(name: \(_bridgeName))"
  }

  private func _handleLinkNotification(_ linkMessage: RTNLLinkMessage) throws {
    var portNotification: PortNotification<Port>?
    let port = try Port(rtnl: linkMessage.link, bridge: self)
    if port._isBridgeSelf, port._rtnl.index == _bridgeIndex {
      if case .new = linkMessage {
        _bridgePort = port
      } else {
        debugPrint("LinuxBridge: bridge device itself removed")
        throw Errno.noSuchAddressOrDevice
      }
    } else if port._rtnl.master == _bridgeIndex {
      if case .new = linkMessage {
        portNotification = .added(port)
        try _addLinkLocalRxTask(port: port)
      } else {
        try _cancelLinkLocalRxTask(port: port)
        portNotification = .removed(port)
      }
    } else {
      debugPrint("LinuxBridge: ignoring port \(port), not a member or us")
    }
    if let portNotification {
      Task { await _portNotificationChannel.send(portNotification) }
    }
  }

  public var notifications: AnyAsyncSequence<PortNotification<Port>> {
    _portNotificationChannel.eraseToAnyAsyncSequence()
  }

  public var defaultPVid: UInt16? {
    _bridgePort!._pvid
  }

  public func getVlans(controller: isolated MRPController<Port>) async -> Set<VLAN> {
    if let vlans = _bridgePort!._vlans {
      Set(vlans.map { VLAN(vid: $0) })
    } else {
      Set()
    }
  }

  public var name: String {
    _bridgePort!.name
  }

  private func _getPorts(family: sa_family_t) async throws -> Set<Port> {
    try await Set(
      _nlLinkSocket.getLinks(family: family).map { try Port(rtnl: $0, bridge: self) }
        .collect()
    )
  }

  private func _getMemberPorts() async throws -> Set<Port> {
    try await _getPorts(family: sa_family_t(AF_BRIDGE)).filter {
      !$0._isBridgeSelf && $0._rtnl.master == _bridgeIndex
    }
  }

  private func _getBridgePort(name: String) async throws -> Port {
    let bridgePorts = try await _getPorts(family: sa_family_t(AF_BRIDGE))
      .filter { $0._isBridgeSelf && $0.name == name }
    guard bridgePorts.count == 1 else {
      throw MRPError.invalidBridgeIdentity
    }
    return bridgePorts.first!
  }

  @_spi(SwiftMRPPrivate)
  public var bridgePort: Port {
    _bridgePort!
  }

  private struct LinkLocalRXTaskKey: Hashable {
    let portID: Port.ID
    let filterRegistration: FilterRegistration
  }

  private func _allocateLinkLocalRxTask(
    port: Port,
    filterRegistration: FilterRegistration
  ) -> Task<(), Error> {
    Task {
      repeat {
        do {
          for try await packet in try await filterRegistration._rxPackets(port: port) {
            await _rxPacketsChannel.send((port.id, packet))
          }
        } catch Errno.interrupted {} // restart on interrupted system call
      } while !Task.isCancelled
    }
  }

  private func _addLinkLocalRxTask(port: Port) throws {
    precondition(!port._isBridgeSelf)
    for filterRegistration in _linkLocalRegistrations {
      let key = LinkLocalRXTaskKey(portID: port.id, filterRegistration: filterRegistration)
      _linkLocalRxTasks[key] = _allocateLinkLocalRxTask(
        port: port,
        filterRegistration: filterRegistration
      )
      debugPrint(
        "LinuxBridge: started link-local RX task for \(port) filter registration \(filterRegistration)"
      )
    }
  }

  private func _cancelLinkLocalRxTask(port: Port) throws {
    precondition(!port._isBridgeSelf)
    try _cancelLinkLocalRxTask(portID: port.id)
  }

  private func _cancelLinkLocalRxTask(portID: Port.ID) throws {
    for filterRegistration in _linkLocalRegistrations {
      let key = LinkLocalRXTaskKey(portID: portID, filterRegistration: filterRegistration)
      guard let index = _linkLocalRxTasks.index(forKey: key) else { continue }
      let task = _linkLocalRxTasks[index].value
      _linkLocalRxTasks.remove(at: index)
      task.cancel()
      debugPrint(
        "LinuxBridge: removed link-local RX task for \(portID) filter registration \(filterRegistration)"
      )
    }
  }

  public func register(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<Port>
  ) async throws {
    guard _isLinkLocal(macAddress: groupAddress) else { return }
    _linkLocalRegistrations.insert(FilterRegistration(
      groupAddress: groupAddress,
      etherType: etherType
    ))
  }

  public func deregister(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<Port>
  ) async throws {
    guard _isLinkLocal(macAddress: groupAddress) else { return }
    _linkLocalRegistrations.remove(FilterRegistration(
      groupAddress: groupAddress,
      etherType: etherType
    ))
  }

  public func run(controller: isolated MRPController<Port>) async throws {
    _bridgePort = try await _getBridgePort(name: _bridgeName)
    _bridgeIndex = _bridgePort!._rtnl.index

    try _nlLinkSocket.subscribeLinks()

    _nlLinkMonitorTask = Task<(), Error> { [self] in
      for try await notification in _nlLinkSocket.notifications {
        do {
          try _handleLinkNotification(notification as! RTNLLinkMessage)
        } catch Errno.noSuchAddressOrDevice {
          throw Errno.noSuchAddressOrDevice
        } catch {}
      }
    }
    _nlNfLogMonitorTask = Task<(), Error> { [self] in
      for try await packet in _nfNlLogRxPackets {
        await _rxPacketsChannel.send(packet)
      }
    }

    let ports = try await _getMemberPorts()
    for port in ports {
      await _portNotificationChannel.send(.added(port))
      try _addLinkLocalRxTask(port: port)
    }
  }

  private func _shutdown() throws {
    let portIDs = _linkLocalRxTasks.keys.map(\.portID)
    for portID in portIDs {
      try? _cancelLinkLocalRxTask(portID: portID)
    }

    _nlNfLogMonitorTask?.cancel()
    _nlLinkMonitorTask?.cancel()

    try? _nlLinkSocket.unsubscribeLinks()

    _bridgePort = nil
    _bridgeIndex = 0
  }

  public func shutdown(controller: isolated MRPController<Port>) async throws {
    try _shutdown()
  }

  private func _add(vlans: Set<VLAN>) async throws {
    try await _bridgePort!._add(vlans: vlans)
  }

  private func _remove(vlans: Set<VLAN>) async throws {
    try await _bridgePort!._remove(vlans: vlans)
  }

  public func tx(
    _ packet: IEEE802Packet,
    on portID: P.ID,
    controller: isolated MRPController<Port>
  ) async throws {
    var serializationContext = SerializationContext()
    let packetType = _isMulticast(macAddress: packet.destMacAddress) ?
      UInt8(PACKET_MULTICAST) : UInt8(PACKET_HOST)
    let address = _makeLinkLayerAddressBytes(
      macAddress: packet.destMacAddress,
      packetType: packetType,
      index: portID
    )
    try packet.serialize(into: &serializationContext)
    try await _txSocket.sendMessage(.init(name: address, buffer: serializationContext.bytes))
  }

  public var rxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)> {
    _rxPacketsChannel.eraseToAnyAsyncSequence()
  }

  private var _nfNlLogRxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)> {
    _nlNfLog.logMessages.compactMap { logMessage in
      guard let hwHeader = logMessage.hwHeader, let payload = logMessage.payload,
            let packet = try? IEEE802Packet(hwHeader: hwHeader, payload: payload)
      else {
        return nil
      }
      return (logMessage.physicalInputDevice, packet)
    }.eraseToAnyAsyncSequence()
  }
}

fileprivate final class FilterRegistration: Equatable, Hashable, Sendable, CustomStringConvertible {
  static func == (_ lhs: FilterRegistration, _ rhs: FilterRegistration) -> Bool {
    _isEqualMacAddress(lhs._groupAddress, rhs._groupAddress) && lhs._etherType == rhs._etherType
  }

  let _groupAddress: EUI48
  let _etherType: UInt16

  init(groupAddress: EUI48, etherType: UInt16) {
    _groupAddress = groupAddress
    _etherType = etherType
  }

  func hash(into hasher: inout Hasher) {
    _hashMacAddress(_groupAddress, into: &hasher)
    _etherType.hash(into: &hasher)
  }

  var description: String {
    "FilterRegistration(_groupAddress: \(_macAddressToString(_groupAddress)), _etherType: \(String(format: "0x%04x", _etherType)))"
  }

  func _rxPackets(port: LinuxPort) async throws -> AnyAsyncSequence<IEEE802Packet> {
    precondition(_isLinkLocal(macAddress: _groupAddress))
    let rxSocket = try Socket(
      ring: IORing.shared,
      domain: sa_family_t(AF_PACKET),
      type: SOCK_RAW,
      protocol: CInt(_etherType.bigEndian)
    )
    try rxSocket.bind(to: _makeLinkLayerAddress(
      macAddress: port.macAddress,
      etherType: _etherType,
      packetType: UInt8(PACKET_MULTICAST),
      index: port.id
    ))
    try rxSocket.addMulticastMembership(for: _makeLinkLayerAddress(
      macAddress: _groupAddress,
      index: port.id
    ))

    return try await rxSocket.receiveMessages(count: port._rtnl.mtu).compactMap { message in
      var deserializationContext = DeserializationContext(message.buffer)
      return try? IEEE802Packet(deserializationContext: &deserializationContext)
    }.eraseToAnyAsyncSequence()
  }
}

extension LinuxBridge: MMRPAwareBridge {
  func register(groupAddress: EUI48, on ports: Set<P>) async throws {
    for port in ports {
      try await (bridgePort._rtnl as! RTNLLinkBridge).add(
        link: port._rtnl,
        groupAddresses: [groupAddress],
        socket: _nlLinkSocket
      )
    }
  }

  func deregister(groupAddress: EUI48, from ports: Set<P>) async throws {
    for port in ports {
      try await (bridgePort._rtnl as! RTNLLinkBridge).remove(
        link: port._rtnl,
        groupAddresses: [groupAddress],
        socket: _nlLinkSocket
      )
    }
  }

  func register(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue,
    on ports: Set<P>
  ) async throws {}
  func deregister(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue,
    from ports: Set<P>
  ) async throws {}
}

extension LinuxBridge: MVRPAwareBridge {
  func register(vlan: VLAN, on ports: Set<P>) async throws {
    try await _add(vlans: [vlan])
    for port in ports {
      try await port._add(vlans: [vlan])
    }
  }

  func deregister(vlan: VLAN, from ports: Set<P>) async throws {
    for port in ports {
      try await port._remove(vlans: [vlan])
    }
    try await _remove(vlans: [vlan])
  }
}

#endif
