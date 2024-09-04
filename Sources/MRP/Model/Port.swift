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

import AsyncExtensions
import IEEE802

public protocol Port: Hashable, Sendable, Identifiable where ID: Hashable & Sendable {
  static func timeSinceEpoch() throws -> UInt32

  var id: ID { get }
  var name: String { get }

  var isOperational: Bool { get }
  var isEnabled: Bool { get }
  var isPointToPoint: Bool { get }

  var macAddress: EUI48 { get }

  var pvid: UInt16? { get }
  var vlans: Set<VLAN> { get }

  // MTU in octets
  var mtu: UInt { get }

  // link speed in kbps
  var linkSpeed: UInt { get }
}

public typealias SRClassPriorityMap = [SRclassID: SRclassPriority]

public protocol AVBPort: Port {
  var isAvbCapable: Bool { get }
  var isAsCapable: Bool { get }

  func getPortTcMaxLatency(for: SRclassPriority) async throws -> Int
}

public enum PortNotification<P: Port>: Sendable {
  case added(P)
  case removed(P)
  case changed(P)

  var port: P {
    switch self {
    case let .added(port):
      port
    case let .removed(port):
      port
    case let .changed(port):
      port
    }
  }
}

public enum SRClassPriorityMapNotification<P: Port>: Sendable {
  case added((P.ID, SRClassPriorityMap))
  case removed((P.ID, SRClassPriorityMap))
  case changed((P.ID, SRClassPriorityMap))

  var portID: P.ID {
    switch self {
    case let .added(n):
      n.0
    case let .removed(n):
      n.0
    case let .changed(n):
      n.0
    }
  }

  var map: SRClassPriorityMap {
    switch self {
    case let .added(n):
      n.1
    case let .removed(n):
      n.1
    case let .changed(n):
      n.1
    }
  }
}

extension Port {
  var contextIdentifiers: Set<MAPContextIdentifier> {
    Set(vlans.map { MAPContextIdentifier(vlan: $0) })
  }
}
