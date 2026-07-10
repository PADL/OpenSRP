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

public protocol Port: Hashable, Sendable, Identifiable where ID: Hashable & Sendable & Codable {
  // a monotonic reference instant, used to order stream reservations by age (youngest-first
  // preemption, Avnu §9.1); monotonic so it never runs backwards like a wall clock can
  static var now: ContinuousClock.Instant { get }

  var id: ID { get }
  var name: String { get }

  var isOperational: Bool { get }
  var isEnabled: Bool { get }
  var isPointToPoint: Bool { get }
  // spanning-tree port state; declarations are not propagated out a non-Forwarding (blocked)
  // port (IEEE 802.1Q 35.1.3.1, 10.3). End stations / ports without STP are Forwarding.
  // nil = indeterminate from this snapshot; the caller keeps the last-known state.
  var stpPortState: STPPortState? { get }

  var macAddress: EUI48 { get }

  var pvid: UInt16? { get }
  var vlans: Set<VLAN> { get }
  // the subset of vlans that are 802.1Q Dynamic VLAN Registration Entries
  var dynamicVlans: Set<VLAN> { get }

  // MTU in octets
  var mtu: UInt { get }

  // link speed in kbps
  var linkSpeed: UInt { get }
}

public typealias SRClassPriorityMap = [SRclassID: SRclassPriority]

public protocol AVBPort: Port {
  var isAvbCapable: Bool { get }
  var isAsCapable: Bool { get async throws }

  // the worst-case per-hop latency (35.2.2.8.6); throws ptpNotReady when gPTP has no meanLinkDelay
  // yet (e.g. the link partner is not up), so the caller substitutes an uncached over-estimate
  func getPortTcMaxLatency(for: SRclassPriority) async throws -> Int

  // The priorities for which priority-based flow control (PFC, 802.1Qbb) is enabled. PFC and the
  // credit-based shaper are mutually exclusive on a priority (802.1Q 34.5), so an SR class whose
  // priority has PFC enabled makes the port an SRP domain boundary port for that class (35.2.1.4).
  var pfcEnabledPriorities: Set<SRclassPriority> { get async throws }

  // 802.3x flow control (clause 31 / Annex 31B PAUSE). MSRP disables it on every
  // AVB-capable port at setup, since AVB ports do not use 802.3x flow control and a
  // received PAUSE must not be allowed to stall reserved-stream egress
  // (IEEE 802.1BA-2011 §6.4).
  func setFlowControl(_ enabled: Bool) async throws
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

// MRP-native spanning-tree CIST status for a port; platforms map their STP source onto this
// so MRP core stays independent of any particular STP implementation.
public enum STPPortRole: Sendable {
  case disabled, root, designated, alternate, backup, master
}

public enum STPPortState: Sendable {
  case disabled, listening, learning, forwarding, blocking
}

public struct STPPortStatus: Sendable {
  public let role: STPPortRole
  public let state: STPPortState

  public init(role: STPPortRole, state: STPPortState) {
    self.role = role
    self.state = state
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

// A port's statically-configured VLAN membership changed; the consumer re-reads
// port.vlans and updates its MVRP declarations (the VID delta is not carried,
// so ordering/duplicate notifications are harmless).
public struct VLANRegistrationNotification<P: Port>: Sendable {
  public let portID: P.ID
}

extension Port {
  var contextIdentifiers: Set<MAPContextIdentifier> {
    Set(vlans.map { MAPContextIdentifier(vlan: $0) })
  }
}
