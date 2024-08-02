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
import AsyncExtensions
import CNetLink
import IORing
import IORingUtils
import NetLink

@_spi(MRPPrivate)
public struct LinuxPort: Port, Sendable {
  public typealias ID = Int

  public static func == (_ lhs: LinuxPort, _ rhs: LinuxPort) -> Bool {
    lhs.id == rhs.id
  }

  private let _rtnl: RTNLLink
  private let _rxPackets = AsyncChannel<IEEE802Packet>()
  private let _ioring = IORing.shared
//  private let _socket: Socket

  init(rtnl: RTNLLink) {
    _rtnl = rtnl
  }

  public func hash(into hasher: inout Hasher) {
    id.hash(into: &hasher)
  }

  public var isOperational: Bool {
    true
  }

  public var isEnabled: Bool {
    true
  }

  public var isPointToPoint: Bool {
    false
  }

  public var name: String {
    _rtnl.name
  }

  public var id: Int {
    _rtnl.index
  }

  public var macAddress: EUI48 {
    fatalError()
  }

  public func addFilter(for macAddress: EUI48, etherType: UInt16) throws {}

  public func removeFilter(for macAddress: EUI48, etherType: UInt16) throws {}

  public func tx(_ packet: IEEE802Packet) async throws {}

  public var rxPackets: AnyAsyncSequence<IEEE802Packet> {
    _rxPackets.eraseToAnyAsyncSequence()
  }
}

@_spi(MRPPrivate)
public struct LinuxPortMonitor: PortMonitor, Sendable {
  public typealias Port = LinuxPort

  private let socket: NLSocket

  public init() async throws {
    socket = try NLSocket(protocol: NETLINK_ROUTE)
    try socket.notifyRtLinks()
  }

  public var ports: [P] {
    get async throws {
      try await socket.getRtLinks().compactMap { link in
        if case let .new(link) = link {
          P(rtnl: link)
        } else {
          nil
        }
      }.collect()
    }
  }

  public var observe: AnyAsyncSequence<PortObservation<Port>> {
    socket.notifications.compactMap { @Sendable notification in
      let link = notification as! RTNLLinkMessage
      switch link {
      case let .new(link):
        return .added(P(rtnl: link))
      case let .del(link):
        return .removed(P(rtnl: link))
      }
    }.eraseToAnyAsyncSequence()
  }
}

#endif
