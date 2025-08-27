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

import IEEE802

enum AttributeEvent: UInt8, Comparable {
  case New = 0
  case JoinIn = 1
  case In = 2
  case JoinMt = 3
  case Mt = 4
  case Lv = 5

  var protocolEvent: ProtocolEvent {
    switch self {
    case .New:
      .rNew
    case .JoinIn:
      .rJoinIn
    case .In:
      .rIn
    case .JoinMt:
      .rJoinMt
    case .Mt:
      .rMt
    case .Lv:
      .rLv
    }
  }

  // note: this comparison is inverted intentionally, as it is used to indicate
  // precedence (e.g. New has higher precedence than Lv)
  static func <(lhs: AttributeEvent, rhs: AttributeEvent) -> Bool {
    lhs.rawValue > rhs.rawValue
  }
}

struct OperationalStatistics {
  var failureToRegisterCount: Int
}

public struct MAPContextIdentifier: Identifiable, Sendable, Hashable, Equatable,
  ExpressibleByIntegerLiteral
{
  public typealias ID = UInt16
  public typealias IntegerLiteralType = ID

  public let id: UInt16

  init(id: UInt16) {
    self.id = id
  }

  public init(integerLiteral value: ID) {
    self.init(id: value)
  }

  init(vlan: VLAN) {
    self.init(id: vlan.vid)
  }

  private init(tci: IEEE802Packet.TCI?) {
    if let tci {
      self.init(id: tci.vid)
    } else {
      self = MAPBaseSpanningTreeContext
    }
  }

  init(packet: IEEE802Packet) {
    self.init(tci: packet.tci)
  }

  var tci: IEEE802Packet.TCI? {
    if self != MAPBaseSpanningTreeContext {
      IEEE802Packet.TCI(id)
    } else {
      nil
    }
  }
}

public typealias MAPContext<P: Port> = Set<P>

let MAPBaseSpanningTreeContext = MAPContextIdentifier(0)

// 200 milliseconds
let JoinTime = Duration.seconds(0.2)
// 5000 milliseconds
let LeaveTime = Duration.seconds(5)
// 10-15 seconds
let LeaveAllTime = 10.0

struct MRPFlag: OptionSet, Sendable {
  typealias RawValue = UInt8

  let rawValue: RawValue

  static let declared = MRPFlag(rawValue: 1 << 0)
  static let registered = MRPFlag(rawValue: 1 << 1)
}

extension IEEE802Packet {
  init(
    destMacAddress: EUI48,
    contextIdentifier: MAPContextIdentifier,
    sourceMacAddress: EUI48,
    etherType: UInt16,
    payload: [UInt8]
  ) {
    self.init(
      destMacAddress: destMacAddress,
      tci: contextIdentifier.tci,
      sourceMacAddress: sourceMacAddress,
      etherType: etherType,
      payload: payload
    )
  }
}
