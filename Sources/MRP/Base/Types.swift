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

enum AttributeEvent: UInt8 {
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
}

struct OperationalStatistics {
  var failureToRegisterCount: Int
}

public typealias EUI48 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

extension UInt64 {
  init(eui48: EUI48) {
    self =
      UInt64(eui48.0 << 40) |
      UInt64(eui48.1 << 32) |
      UInt64(eui48.2 << 24) |
      UInt64(eui48.3 << 16) |
      UInt64(eui48.4 << 8) |
      UInt64(eui48.5 << 0)
  }
}

// used by MVRP and MMRP (forwarded by bridges that do not support application protocol)
@_spi(SwiftMRPPrivate)
public let CustomerBridgeMRPGroupAddress: EUI48 = (0x01, 0x80, 0xC2, 0x00, 0x00, 0x21)

// used by MSRP (not forwarded by bridges)
@_spi(SwiftMRPPrivate)
public let IndividualLANScopeGroupAddress: EUI48 = (0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E)

func _isLinkLocal(macAddress: EUI48) -> Bool {
  macAddress.0 == 0x01 && macAddress.1 == 0x80 && macAddress.2 == 0xC2 && macAddress
    .3 == 0x00 && macAddress.4 == 0x00 && macAddress.5 & 0xF0 == 0
}

func _isEqualMacAddress(_ lhs: EUI48, _ rhs: EUI48) -> Bool {
  lhs.0 == rhs.0 &&
    lhs.1 == rhs.1 &&
    lhs.2 == rhs.2 &&
    lhs.3 == rhs.3 &&
    lhs.4 == rhs.4 &&
    lhs.5 == rhs.5
}

func _isMulticast(macAddress: EUI48) -> Bool {
  macAddress.0 & 1 != 0
}

func _hashMacAddress(_ macAddress: EUI48, into hasher: inout Hasher) {
  macAddress.0.hash(into: &hasher)
  macAddress.1.hash(into: &hasher)
  macAddress.2.hash(into: &hasher)
  macAddress.3.hash(into: &hasher)
  macAddress.4.hash(into: &hasher)
  macAddress.5.hash(into: &hasher)
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
      IEEE802Packet.TCI(tci: id)
    } else {
      nil
    }
  }
}

public typealias MAPContext<P: Port> = Set<P>

let MAPBaseSpanningTreeContext = MAPContextIdentifier(0)

let JoinTime = Duration.seconds(0.2)
let LeaveTime = Duration.seconds(1)
let LeaveAllTime = 1.0

struct MRPFlag: OptionSet, Sendable {
  typealias RawValue = UInt8

  let rawValue: RawValue

  static let declared = MRPFlag(rawValue: 1 << 0)
  static let registered = MRPFlag(rawValue: 1 << 1)
}
