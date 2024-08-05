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

public struct LinuxPort: Port, Sendable {
  public typealias ID = Int

  public static func == (_ lhs: LinuxPort, _ rhs: LinuxPort) -> Bool {
    lhs.id == rhs.id
  }

  fileprivate let _rtnl: RTNLLink
  private let _socket: Socket

  private static func _makeSll(
    macAddress: EUI48,
    etherType: UInt16 = UInt16(ETH_P_ALL),
    index: Int
  ) -> sockaddr_ll {
    var sll = sockaddr_ll()
    sll.sll_family = UInt16(AF_PACKET)
    sll.sll_protocol = etherType.bigEndian
    sll.sll_ifindex = CInt(index)
    sll.sll_halen = UInt8(ETH_ALEN)
    sll.sll_addr.0 = macAddress.0
    sll.sll_addr.1 = macAddress.1
    sll.sll_addr.2 = macAddress.2
    sll.sll_addr.3 = macAddress.3
    sll.sll_addr.4 = macAddress.4
    sll.sll_addr.5 = macAddress.5
    return sll
  }

  private var _sll: sockaddr_ll {
    Self._makeSll(macAddress: macAddress, index: 0)
  }

  init(rtnl: RTNLLink) throws {
    _rtnl = rtnl
    _socket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_PACKET), type: SOCK_RAW)
    try _socket.bind(to: _sll)
    try _socket.bindTo(device: name)
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
    nil
  }

  public var vlans: Set<VLAN> {
    Set([])
  }

  private func _makeBpfFilter(etherType: UInt16) -> [sock_filter] {
    let filter = [
      sock_filter(code: 0x28, jt: 0, jf: 0, k: 0x0000_000C),
      sock_filter(code: 0x15, jt: 5, jf: 0, k: UInt32(etherType)),
      sock_filter(code: 0x15, jt: 2, jf: 0, k: 0x0000_8100),
      sock_filter(code: 0x15, jt: 1, jf: 0, k: 0x0000_88A8),
      sock_filter(code: 0x15, jt: 0, jf: 3, k: 0x0000_9100),
      sock_filter(code: 0x28, jt: 0, jf: 0, k: 0x0000_0010),
      sock_filter(code: 0x15, jt: 0, jf: 1, k: UInt32(etherType)),
      sock_filter(code: 0x06, jt: 0, jf: 0, k: 0x0004_0000),
      sock_filter(code: 0x06, jt: 0, jf: 0, k: 0x0000_0000),
    ]
    return filter
  }

  private func _addOrDropBpfFilter(etherType: UInt16, add: Bool) throws {
    var filter = _makeBpfFilter(etherType: etherType)
    try filter.withUnsafeMutableBufferPointer {
      var bpf = sock_fprog(len: UInt16($0.count), filter: $0.baseAddress!)
      let option = add ? SO_ATTACH_FILTER : SO_DETACH_FILTER
      try _socket.setOpaqueOption(level: SOL_SOCKET, option: option, to: &bpf)
    }
  }

  public func addFilter(for macAddress: EUI48, etherType: UInt16) throws {
    if macAddress.0 & 1 != 0 {
      let sll = Self._makeSll(macAddress: macAddress, etherType: etherType, index: id)
      try _socket.addMulticastMembership(for: sll)
      try _addOrDropBpfFilter(etherType: etherType, add: true)
    }
  }

  public func removeFilter(for macAddress: EUI48, etherType: UInt16) throws {
    try _addOrDropBpfFilter(etherType: etherType, add: false)
    if macAddress.0 & 1 != 0 {
      let sll = Self._makeSll(macAddress: macAddress, etherType: etherType, index: id)
      try _socket.dropMulticastMembership(for: sll)
    }
  }

  public func tx(_ packet: IEEE802Packet) async throws {
    var serializationContext = SerializationContext()
    try packet.serialize(into: &serializationContext)
    // let address = Self._makeSll(macAddress: packet.destMacAddress, etherType: packet.etherType,
    // index: id)
    // namespace issue means we can't instantiate IORing.Message by name
    try await _socket.sendMessage(.init(name: nil, buffer: serializationContext.bytes))
    // try await _socket.send(serializationContext.bytes)
  }

  public var rxPackets: AnyAsyncSequence<IEEE802Packet> {
    get async throws {
      let rxPackets = try await _socket.receiveMessages(count: _rtnl.mtu)
//      let rxPackets: AnyAsyncSequence<[UInt8]> = try await _socket.receive(count: _rtnl.mtu)
      return rxPackets.compactMap { message in
        var deserializationContext = DeserializationContext(message.buffer)
        return try? IEEE802Packet(deserializationContext: &deserializationContext)
      }.eraseToAnyAsyncSequence()
    }
  }
}

private extension LinuxPort {
  var _vlans: Set<UInt16>? {
    (_rtnl as! RTNLLinkBridge).bridgeTaggedVLANs
  }

  var _pvid: UInt16? {
    (_rtnl as! RTNLLinkBridge).bridgePVID
  }
}

public final class LinuxBridge: Bridge, @unchecked Sendable {
  public typealias Port = LinuxPort

  private let _socket: NLSocket
  private let _bridgePort = ManagedCriticalState<Port?>(nil)
  private var _task: Task<(), Error>!
  private let _portNotificationChannel = AsyncChannel<PortNotification<Port>>()

  public init(name: String) async throws {
    _socket = try NLSocket(protocol: NETLINK_ROUTE)
    try _socket.subscribeLinks()
    let bridgePorts = try await _getPorts(family: sa_family_t(AF_BRIDGE))
      .filter { $0._isBridgeSelf && $0.name == name }
    guard bridgePorts.count == 1 else {
      throw MRPError.invalidBridgeIdentity
    }
    _bridgePort.withCriticalRegion { $0 = bridgePorts.first! }

    _task = Task<(), Error> { [self] in
      for try await notification in _socket.notifications {
        do {
          var portNotification: PortNotification<Port>!
          try _bridgePort.withCriticalRegion { bridgePort in
            let bridgeIndex = bridgePort!._rtnl.index
            let linkMessage = notification as! RTNLLinkMessage
            let port = try Port(rtnl: linkMessage.link)
            if port._isBridgeSelf, port._rtnl.index == bridgeIndex {
              if case .new = linkMessage {
                bridgePort = port
              } else {
                fatalError("bridge itself was deleted") // FIXME: do something sensible
              }
            } else if port._rtnl.master == bridgeIndex {
              if case .new = linkMessage {
                portNotification = .added(port)
              } else {
                portNotification = .removed(port)
              }
            }
          }
          await _portNotificationChannel.send(portNotification)
        } catch {}
      }
    }
  }

  public var defaultPVid: UInt16? {
    _bridgePort.criticalState!._pvid
  }

  public var vlans: Set<VLAN> {
    if let vlans = _bridgePort.criticalState!._vlans {
      Set(vlans.map { VLAN(vid: $0) })
    } else {
      Set()
    }
  }

  public var name: String {
    _bridgePort.criticalState!.name
  }

  private func _getPorts(family: sa_family_t = sa_family_t(AF_UNSPEC)) async throws -> Set<Port> {
    try await Set(_socket.getLinks(family: family).map { try Port(rtnl: $0) }.collect())
  }

  private var _bridgeIndex: Int {
    _bridgePort.criticalState!._rtnl.index
  }

  public func getPorts() async throws -> Set<Port> {
    let bridgeIndex = _bridgeIndex
    return try await _getPorts().filter {
      !$0._isBridgeSelf && $0._rtnl.master == bridgeIndex
    }
  }

  public var notifications: AnyAsyncSequence<PortNotification<Port>> {
    _socket.notifications.compactMap { @Sendable notification in
      let link = notification as! RTNLLinkMessage
      switch link {
      case let .new(link):
        return try .added(Port(rtnl: link))
      case let .del(link):
        return try .removed(Port(rtnl: link))
      }
    }.eraseToAnyAsyncSequence()
  }
}

#endif
