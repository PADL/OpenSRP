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

  private let _rtnl: RTNLLink
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

  public var name: String {
    _rtnl.name
  }

  public var id: Int {
    _rtnl.index
  }

  public var macAddress: EUI48 {
    _rtnl.macAddress
  }

  public func addFilter(for macAddress: EUI48, etherType: UInt16) throws {
    if macAddress.0 & 1 != 0 {
      let sll = Self._makeSll(macAddress: macAddress, etherType: etherType, index: id)
      try _socket.addMulticastMembership(for: sll)
    }
  }

  public func removeFilter(for macAddress: EUI48, etherType: UInt16) throws {
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
    // try await _socket.sendMessage(.init(name: nil, buffer: serializationContext.bytes))
    try await _socket.send(serializationContext.bytes)
  }

  public var rxPackets: AnyAsyncSequence<IEEE802Packet> {
    get async throws {
      let rxPackets: AnyAsyncSequence<[UInt8]> = try await _socket.receive(count: _rtnl.mtu)
      return rxPackets.compactMap { buffer in
        var deserializationContext = DeserializationContext(buffer)
        return try? IEEE802Packet(deserializationContext: &deserializationContext)
      }.eraseToAnyAsyncSequence()
    }
  }
}

public struct LinuxPortMonitor: PortMonitor, Sendable {
  public typealias Port = LinuxPort

  private let socket: NLSocket

  public init() async throws {
    socket = try NLSocket(protocol: NETLINK_ROUTE)
    try socket.notifyRtLinks()
  }

  public var ports: [Port] {
    get async throws {
      try await socket.getRtLinks().compactMap { link in
        if case let .new(link) = link {
          try Port(rtnl: link)
        } else {
          nil
        }
      }.collect()
    }
  }

  public var notifications: AnyAsyncSequence<PortNotification<Port>> {
    socket.notifications.compactMap { @Sendable notification in
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
