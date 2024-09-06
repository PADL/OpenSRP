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
import IEEE802
import IORing
import IORingUtils
import NetLink
import PMC
import SocketAddress
import SystemPackage

private func _mapUPToSRClassPriority(_ up: UInt8) -> SRclassPriority {
  guard let srClassPriority = SRclassPriority(rawValue: up) else {
    return SRclassPriority.BE // best effort
  }
  return srClassPriority
}

private func _mapSRClassPriorityToUP(_ srClassPriority: SRclassPriority) -> UInt8 {
  srClassPriority.rawValue
}

private func _mapTCToSRClassID(_ tc: UInt8) -> SRclassID? {
  guard tc <= SRclassID.A.rawValue else {
    return nil
  }

  return SRclassID(rawValue: SRclassID.A.rawValue - tc)
}

private func _mapSRClassIDToTC(_ srClassID: SRclassID) -> UInt8 {
  SRclassID.A.rawValue - srClassID.rawValue
}

private func _makeLinkLayerAddress(
  family: sa_family_t = sa_family_t(AF_PACKET),
  macAddress: EUI48? = nil,
  etherType: UInt16 = UInt16(ETH_P_ALL),
  packetType: UInt8 = 0,
  index: Int? = nil
) -> sockaddr_ll {
  var sll = sockaddr_ll()
  sll.sll_family = UInt16(family)
  sll.sll_protocol = etherType.bigEndian
  sll.sll_ifindex = CInt(index ?? 0)
  sll.sll_pkttype = packetType
  if let macAddress {
    sll.sll_halen = UInt8(ETH_ALEN)
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
  packetType: UInt8 = 0,
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

// TODO: use NetLink to avoid blocking I/O
private func _ethToolIoctl<T>(fileHandle: FileHandle, name: String, arg: inout T) throws {
  guard name.count < Int(IFNAMSIZ) else { throw Errno.outOfRange }

  try withUnsafeMutablePointer(to: &arg) {
    try $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
      var ifr = ifreq()
      ifr.ifr_ifru.ifru_data = UnsafeMutablePointer($0)

      withUnsafeMutablePointer(to: &ifr.ifr_ifrn.ifrn_name) {
        let start = $0.propertyBasePointer(to: \.0)!
        memcpy(start, name, name.count)
      }

      if ioctl(fileHandle.fileDescriptor, UInt(SIOCETHTOOL), &ifr) < 0 {
        throw Errno(rawValue: errno)
      }
    }
  }
}

struct EthernetChannelParameterSet: Sendable {
  let rx: Int
  let tx: Int
  let other: Int
  let combined: Int
}

struct EthernetChannelParameters: Sendable {
  let max: EthernetChannelParameterSet
  let current: EthernetChannelParameterSet

  init(_ channels: ethtool_channels) {
    self.max = EthernetChannelParameterSet(
      rx: Int(channels.max_rx),
      tx: Int(channels.max_tx),
      other: Int(channels.max_other),
      combined: Int(channels.max_combined)
    )
    current = EthernetChannelParameterSet(
      rx: Int(channels.rx_count),
      tx: Int(channels.tx_count),
      other: Int(channels.other_count),
      combined: Int(channels.combined_count)
    )
  }
}

private func _getEthChannelCount(
  fileHandle: FileHandle,
  name: String
) throws -> EthernetChannelParameters {
  var channels = ethtool_channels()
  channels.cmd = UInt32(ETHTOOL_GCHANNELS)
  try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &channels)
  return EthernetChannelParameters(channels)
}

private func _getEthLinkSettings(
  fileHandle: FileHandle,
  name: String
) throws -> (ethtool_link_settings, [UInt32]) {
  var linkSettingsBuffer = [UInt8](
    repeating: 0,
    count: MemoryLayout<ethtool_link_settings>.size + 3 * Int(SCHAR_MAX)
  )
  try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &linkSettingsBuffer)

  return try withUnsafeMutablePointer(to: &linkSettingsBuffer) {
    try $0.withMemoryRebound(to: ethtool_link_settings.self, capacity: 1) { linkSettings in
      guard linkSettings.pointee.link_mode_masks_nwords < 0 && linkSettings.pointee
        .cmd == UInt32(ETHTOOL_GLINKSETTINGS)
      else {
        throw Errno.invalidArgument
      }

      linkSettings.pointee.link_mode_masks_nwords = -linkSettings.pointee.link_mode_masks_nwords
      try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &linkSettings.pointee)

      guard linkSettings.pointee.link_mode_masks_nwords > 0 && linkSettings.pointee
        .cmd == UInt32(ETHTOOL_GLINKSETTINGS)
      else {
        throw Errno.invalidArgument
      }

      // layout is:
      // __u32 reserved[7];
      // __u32 map_supported[link_mode_masks_nwords];
      // __u32 map_advertising[link_mode_masks_nwords];
      // __u32 map_lp_advertising[link_mode_masks_nwords];

      let linkModes = withUnsafePointer(to: &linkSettings.pointee.reserved.6) {
        Array(UnsafeBufferPointer<UInt32>(
          start: $0 + 1,
          count: 3 * Int(linkSettings.pointee.link_mode_masks_nwords)
        ))
      }

      return (linkSettings.pointee, linkModes)
    }
  }
}

private func _getEthLinkSettingsCompat(
  fileHandle: FileHandle,
  name: String
) throws -> (ethtool_link_settings, [UInt32]) {
  var legacyLinkSettings = ethtool_cmd()
  legacyLinkSettings.cmd = UInt32(ETHTOOL_GSET)
  try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &legacyLinkSettings)

  var linkSettings = ethtool_link_settings()

  linkSettings.cmd = UInt32(ETHTOOL_GLINKSETTINGS)

  linkSettings.speed = UInt32(legacyLinkSettings.speed)
  linkSettings.duplex = legacyLinkSettings.duplex
  linkSettings.port = legacyLinkSettings.port
  linkSettings.phy_address = legacyLinkSettings.phy_address
  linkSettings.autoneg = legacyLinkSettings.autoneg
  linkSettings.mdio_support = legacyLinkSettings.mdio_support
  linkSettings.eth_tp_mdix = legacyLinkSettings.eth_tp_mdix
  linkSettings.eth_tp_mdix_ctrl = legacyLinkSettings.eth_tp_mdix_ctrl

  let linkModes: [UInt32] = [
    legacyLinkSettings.supported,
    legacyLinkSettings.advertising,
    legacyLinkSettings.lp_advertising,
  ]

  return (linkSettings, linkModes)
}

public struct LinuxPort: Port, AVBPort, Sendable, CustomStringConvertible {
  public static func timeSinceEpoch() throws -> UInt32 {
    var tv = timeval()
    guard gettimeofday(&tv, nil) == 0 else {
      throw Errno(rawValue: errno)
    }
    return UInt32(tv.tv_sec)
  }

  public typealias ID = Int

  public static func == (lhs: LinuxPort, rhs: LinuxPort) -> Bool {
    lhs.id == rhs.id
  }

  fileprivate let _rtnl: RTNLLink
  fileprivate let _txSocket: Socket
  private let _linkSettings: (ethtool_link_settings, [UInt32])
  private let _channels: EthernetChannelParameters?
  fileprivate weak var _bridge: LinuxBridge?

  init(rtnl: RTNLLink, bridge: LinuxBridge) throws {
    _rtnl = rtnl
    _bridge = bridge
    _txSocket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_PACKET), type: SOCK_RAW)
    // shouldn't need to join multicast group if we are only sending packets

    let fileHandle = try FileHandle(
      fileDescriptor: socket(CInt(AF_PACKET), Int32(SOCK_DGRAM.rawValue), 0),
      closeOnDealloc: true
    )

    do {
      _linkSettings = try _getEthLinkSettings(fileHandle: fileHandle, name: _rtnl.name)
    } catch {
      _linkSettings = try _getEthLinkSettingsCompat(fileHandle: fileHandle, name: _rtnl.name)
    }

    // we allow this to fail, port won't be AVB capable but that is OK
    _channels = try? _getEthChannelCount(fileHandle: fileHandle, name: _rtnl.name)
  }

  public var description: String {
    name
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
    _operPointToPointMAC || _rtnl.flags & IFF_POINTOPOINT != 0
  }

  private var _operPointToPointMAC: Bool {
    _linkSettings.0.duplex == DUPLEX_FULL
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

  public var mtu: UInt {
    _rtnl.mtu
  }

  public var linkSpeed: UInt {
    UInt(_linkSettings.0.speed) * 1000
  }

  public var isAvbCapable: Bool {
    guard let _channels else { return false }
    return _channels.current.tx > 2 || _channels.current.combined > 2
  }

  private func _getMeanLinkDelay() async throws -> PTP.TimeInterval {
    guard let _bridge else { throw MRPError.internalError }
    let portNumber = try await _bridge._getPtpPortProperties(for: self).portIdentity.portNumber
    let portDataSet = try await _bridge._pmc.getPortDataSet(portNumber: portNumber)
    return portDataSet.meanLinkDelay
  }

  public func getPortTcMaxLatency(for: SRclassPriority) async throws -> Int {
    // PTP timeinterval is nanoseconds * (1 << 16)
    let meanLinkDelay = try await _getMeanLinkDelay()
    return Int(meanLinkDelay >> 16)
  }

  public var isAsCapable: Bool {
    get async throws {
      guard let _bridge else { throw MRPError.internalError }
      let portNumber = try await _bridge._getPtpPortProperties(for: self).portIdentity.portNumber
      let portDataSet = try await _bridge._pmc.getPortDataSetNP(portNumber: portNumber)
      return portDataSet.asCapable != 0
    }
  }
}

private extension LinuxPort {
  var _vlans: Set<UInt16>? {
    (_rtnl as? RTNLLinkBridge)?.bridgeTaggedVLANs
  }

  var _untaggedVlans: Set<UInt16>? {
    (_rtnl as? RTNLLinkBridge)?.bridgeUntaggedVLANs
  }

  var _pvid: UInt16? {
    (_rtnl as? RTNLLinkBridge)?.bridgePVID
  }

  func _add(vlan: VLAN) async throws {
    guard let rtnl = _rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }

    var flags = Int32(0)

    if _untaggedVlans?.contains(vlan.vid) ?? false {
      // preserve untagging status, this may not be on spec but saves blowing away management
      // interface
      flags |= BRIDGE_VLAN_INFO_UNTAGGED
    }
    if _pvid == vlan.vid {
      flags |= BRIDGE_VLAN_INFO_PVID
    }

    try await rtnl.add(vlans: Set([vlan.vid]), flags: UInt16(flags), socket: _bridge!._nlLinkSocket)
  }

  func _remove(vlan: VLAN) async throws {
    guard let rtnl = _rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }

    try await rtnl.remove(vlans: Set([vlan.vid]), socket: _bridge!._nlLinkSocket)
  }
}

public actor LinuxBridge: Bridge, CustomStringConvertible {
  public typealias P = LinuxPort

  fileprivate let _nlLinkSocket: NLSocket
  private let _nlNfLog: NFNLLog
  private let _nlQDiscHandle: UInt16?
  private var _nlNfLogMonitorTask: Task<(), Error>!
  private var _nlLinkMonitorTask: Task<(), Error>!
  private let _bridgeName: String
  private var _bridgeIndex: Int = 0
  private var _bridgePort: P?
  private let _portNotificationChannel = AsyncChannel<PortNotification<P>>()
  private let _rxPacketsChannel = AsyncThrowingChannel<(P.ID, IEEE802Packet), Error>()
  private var _linkLocalRegistrations = Set<FilterRegistration>()
  private var _linkLocalRxTasks = [LinkLocalRXTaskKey: Task<(), Error>]()
  private let _srClassPriorityMapNotificationChannel =
    AsyncChannel<SRClassPriorityMapNotification<P>>()
  fileprivate let _pmc: PTPManagementClient
  private var _portPropertiesCache = [P.ID: PortPropertiesNP]()

  public init(
    name: String,
    netFilterGroup group: Int,
    qDiscHandle: UInt16? = nil,
    ptpManagementClientSocketPath: String? = nil
  ) async throws {
    _bridgeName = name
    _nlLinkSocket = try NLSocket(protocol: NETLINK_ROUTE)
    _nlNfLog = try NFNLLog(group: UInt16(group))
    _nlQDiscHandle = qDiscHandle
    _pmc = try await PTPManagementClient(path: ptpManagementClientSocketPath)
  }

  public nonisolated var description: String {
    _bridgeName
  }

  private func _handleLinkNotification(_ linkMessage: RTNLLinkMessage) throws {
    var portNotification: PortNotification<P>?
    let port = try P(rtnl: linkMessage.link, bridge: self)
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

  public nonisolated var notifications: AnyAsyncSequence<PortNotification<P>> {
    _portNotificationChannel.eraseToAnyAsyncSequence()
  }

  private func _handleTCNotification(_ tcMessage: RTNLTCMessage) throws {
    // all we are really interested is in SR class remappings
    guard let qDisc = tcMessage.tc as? RTNLMQPrioQDisc,
          let _nlQDiscHandle,
          qDisc.handle >> 16 == _nlQDiscHandle,
          let srClassPriorityMap = qDisc.srClassPriorityMap else { return }
    let tcNotification: SRClassPriorityMapNotification<P> = if case .new = tcMessage {
      .added(srClassPriorityMap)
    } else {
      .removed(srClassPriorityMap)
    }
    Task { await _srClassPriorityMapNotificationChannel.send(tcNotification) }
  }

  public var defaultPVid: UInt16? {
    _bridgePort?._pvid
  }

  public func getVlans(controller: isolated MRPController<P>) async -> Set<VLAN> {
    if let vlans = await _bridgePort?._vlans {
      Set(vlans.map { VLAN(vid: $0) })
    } else {
      Set()
    }
  }

  public var name: String {
    _bridgePort!.name
  }

  private func _getPorts(family: sa_family_t) async throws -> Set<P> {
    try await Set(
      _nlLinkSocket.getLinks(family: family).map { try P(rtnl: $0, bridge: self) }
        .collect()
    )
  }

  private func _getMemberPorts() async throws -> Set<P> {
    try await _getPorts(family: sa_family_t(AF_BRIDGE)).filter {
      !$0._isBridgeSelf && $0._rtnl.master == _bridgeIndex
    }
  }

  private func _getBridgePort(name: String) async throws -> P {
    let bridgePorts = try await _getPorts(family: sa_family_t(AF_BRIDGE))
      .filter { $0._isBridgeSelf && $0.name == name }
    guard bridgePorts.count == 1 else {
      throw MRPError.invalidBridgeIdentity
    }
    return bridgePorts.first!
  }

  package var bridgePort: P {
    _bridgePort!
  }

  private struct LinkLocalRXTaskKey: Hashable {
    let portID: P.ID
    let filterRegistration: FilterRegistration
  }

  private func _allocateLinkLocalRxTask(
    port: P,
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

  private func _addLinkLocalRxTask(port: P) throws {
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

  private func _cancelLinkLocalRxTask(port: P) throws {
    precondition(!port._isBridgeSelf)
    try _cancelLinkLocalRxTask(portID: port.id)
  }

  private func _cancelLinkLocalRxTask(portID: P.ID) throws {
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
    controller: MRPController<P>
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
    controller: MRPController<P>
  ) async throws {
    guard _isLinkLocal(macAddress: groupAddress) else { return }
    _linkLocalRegistrations.remove(FilterRegistration(
      groupAddress: groupAddress,
      etherType: etherType
    ))
  }

  public func run(controller: MRPController<P>) async throws {
    _bridgePort = try await _getBridgePort(name: _bridgeName)
    _bridgeIndex = _bridgePort!._rtnl.index

    try _nlLinkSocket.subscribeLinks()
    try _nlLinkSocket.subscribeTC()

    _nlLinkMonitorTask = Task<(), Error> { [self] in
      for try await notification in _nlLinkSocket.notifications {
        do {
          switch notification {
          case let linkNotification as RTNLLinkMessage:
            try _handleLinkNotification(linkNotification)
          case let tcNotification as RTNLTCMessage:
            try _handleTCNotification(tcNotification)
          default:
            break
          }
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

    try? _nlLinkSocket.unsubscribeTC()
    try? _nlLinkSocket.unsubscribeLinks()

    _bridgePort = nil
    _bridgeIndex = 0
  }

  public func shutdown(controller: MRPController<P>) async throws {
    try _shutdown()
  }

  private func _add(vlan: VLAN) async throws {
    guard let _bridgePort else { throw MRPError.internalError }
    try await _bridgePort._add(vlan: vlan)
  }

  private func _remove(vlan: VLAN) async throws {
    guard let _bridgePort else { throw MRPError.internalError }
    try await _bridgePort._remove(vlan: vlan)
  }

  public func tx(
    _ packet: IEEE802Packet,
    on port: P,
    controller: MRPController<P>
  ) async throws {
    let address = _makeLinkLayerAddressBytes(
      macAddress: packet.destMacAddress,
      etherType: packet.etherType,
      index: port.id
    )

    var serializationContext = SerializationContext()
    try packet.serialize(into: &serializationContext)
    try await port._txSocket.sendMessage(.init(
      name: address,
      buffer: serializationContext.bytes
    ))
  }

  public nonisolated var rxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)> {
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
  static func == (lhs: FilterRegistration, rhs: FilterRegistration) -> Bool {
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

    return try await rxSocket.receiveMessages(count: Int(port._rtnl.mtu)).compactMap { message in
      var deserializationContext = DeserializationContext(message.buffer)
      return try? IEEE802Packet(deserializationContext: &deserializationContext)
    }.eraseToAnyAsyncSequence()
  }
}

extension LinuxBridge: MMRPAwareBridge {
  func register(macAddress: EUI48) async throws {
    guard let rtnl = bridgePort._rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }
    try await rtnl.add(fdbEntry: macAddress, socket: _nlLinkSocket)
  }

  func deregister(macAddress: EUI48) async throws {
    guard let rtnl = bridgePort._rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }
    try await rtnl.remove(fdbEntry: macAddress, socket: _nlLinkSocket)
  }

  func register(groupAddress: EUI48, vlan: VLAN?, on ports: Set<P>) async throws {
    guard let rtnl = bridgePort._rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }
    guard _isMulticast(macAddress: groupAddress) else { throw Errno.invalidArgument }

    for port in ports {
      try await rtnl.add(
        link: port._rtnl,
        groupAddresses: [groupAddress],
        vlanID: vlan?.vid,
        socket: _nlLinkSocket
      )
    }
  }

  func deregister(groupAddress: EUI48, vlan: VLAN?, from ports: Set<P>) async throws {
    guard let rtnl = bridgePort._rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }
    guard _isMulticast(macAddress: groupAddress) else { throw Errno.invalidArgument }

    for port in ports {
      try? await rtnl.remove(
        link: port._rtnl,
        groupAddresses: [groupAddress],
        vlanID: vlan?.vid,
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
  nonisolated var hasLocalMVRPApplicant: Bool { true }

  func register(vlan: VLAN, on ports: Set<P>) async throws {
    try await _add(vlan: vlan)
    for port in ports {
      try await port._add(vlan: vlan)
    }
  }

  func deregister(vlan: VLAN, from ports: Set<P>) async throws {
    for port in ports {
      try await port._remove(vlan: vlan)
    }
    try await _remove(vlan: vlan)
  }
}

extension LinuxBridge: MSRPAwareBridge {
  func adjustCreditBasedShaper(
    port: P,
    srClass: SRclassID,
    idleSlope: Int,
    sendSlope: Int,
    hiCredit: Int,
    loCredit: Int
  ) async throws {
    guard let _nlQDiscHandle else {
      throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
    }
    let parent = UInt32(_nlQDiscHandle) << 16 | UInt32(1 + _mapSRClassIDToTC(srClass))
    if hiCredit == 0, loCredit == 0, idleSlope == 0 {
      try await port._rtnl.remove(handle: 0, parent: parent, socket: _nlLinkSocket)
    } else {
      try await port._rtnl.add(
        handle: 0, // this allows the kernel to assign a handle
        parent: parent,
        offload: true,
        hiCredit: Int32(hiCredit),
        loCredit: Int32(loCredit),
        idleSlope: Int32(idleSlope),
        sendSlope: Int32(sendSlope),
        socket: _nlLinkSocket
      )
    }
  }

  func getSRClassPriorityMap(port: P) async throws -> SRClassPriorityMap? {
    let qDiscs = try await _nlLinkSocket.getQDiscs(
      family: sa_family_t(AF_UNSPEC),
      interfaceIndex: port.id
    ).filter { $0.index == port.id }.collect()

    guard let qDisc = qDiscs.compactMap({ $0 as? RTNLMQPrioQDisc }).first,
          let _nlQDiscHandle,
          qDisc.handle >> 16 == _nlQDiscHandle
    else {
      return nil
    }
    return qDisc.srClassPriorityMap?.1
  }

  nonisolated var srClassPriorityMapNotifications: AnyAsyncSequence<
    SRClassPriorityMapNotification<P>
  > {
    _srClassPriorityMapNotificationChannel.eraseToAnyAsyncSequence()
  }

  fileprivate func _getPtpPortProperties(for port: P) async throws -> PortPropertiesNP {
    if let portProperties = _portPropertiesCache[port.id] { return portProperties }
    let defaultDataSet = try await _pmc.getDefaultDataSet()
    for portNumber in 1...defaultDataSet.numberPorts {
      if let portProperties = try? await _pmc.getPortPropertiesNP(portNumber: portNumber),
         portProperties.interface.description == port.name
      {
        _portPropertiesCache[port.id] = portProperties
        return portProperties
      }
    }
    _portPropertiesCache[port.id] = nil
    throw PTP.Error.unknownPort
  }
}

fileprivate extension RTNLMQPrioQDisc {
  var srClassPriorityMap: (LinuxPort.ID, SRClassPriorityMap)? {
    guard let priorityMap else { return nil }

    var srClassPriorityMap = SRClassPriorityMap()

    for (up, tc) in priorityMap {
      guard let srClassID = _mapTCToSRClassID(tc) else { continue }
      let srClassPriority = _mapUPToSRClassPriority(up)
      srClassPriorityMap[srClassID] = srClassPriority
    }

    return (index, srClassPriorityMap)
  }
}

fileprivate extension UnsafeMutablePointer {
  func propertyBasePointer<Property>(to property: KeyPath<Pointee, Property>)
    -> UnsafeMutablePointer<Property>?
  {
    guard let offset = MemoryLayout<Pointee>.offset(of: property) else { return nil }
    return (UnsafeMutableRawPointer(self) + offset).assumingMemoryBound(to: Property.self)
  }
}
#endif
