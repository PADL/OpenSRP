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

// used by MSRP (not forwarded by bridges)
let CustomerBridgeMVRPGroupAddress: EUI48 = (0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E)

// used by MVRP and MMRP (forwarded by bridges that do not support application protocol)
let IndividualLANScopeGroupAddress: EUI48 = (0x01, 0x80, 0xC2, 0x00, 0x00, 0x21)

func _isLinkLocal(macAddress: EUI48) -> Bool {
  macAddress.0 == 0x01 && macAddress.1 == 0x80 && macAddress.2 == 0xC2 && macAddress
    .3 == 0x00 && macAddress.4 == 0x00 && macAddress.5 & 0xF0 == 0
}

struct MAPContextIdentifier: Identifiable, Sendable, Hashable, Equatable,
  ExpressibleByIntegerLiteral
{
  typealias ID = UInt16
  typealias IntegerLiteralType = ID

  let id: UInt16

  init(id: UInt16) {
    self.id = id
  }

  init(integerLiteral value: ID) {
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

typealias MAPContext<P: Port> = Set<P>

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

// c) The Message contains a VectorAttribute (10.8.1.2) where the range defined
// by the FirstValue and NumberOfValues includes the attribute value associated
// with the state machine.

protocol Value: SerDes, Equatable {
  var index: Int { get }

  init(firstValue: Self?, index: Int)
}

extension Value {
  init(index: Int) {
    self.init(firstValue: nil, index: index)
  }
}

struct AnyValue: Value, Equatable {
  static func == (lhs: AnyValue, rhs: AnyValue) -> Bool {
    guard let lhs = try? lhs.serialized(), let rhs = try? rhs.serialized() else {
      return false
    }
    return lhs == rhs
  }

  private let _value: any Value
  private let _isEqual: @Sendable (_: any Value, _: AnyValue) -> Bool

  init<V: Value>(_ value: V) {
    _value = value

    _isEqual = { lhs, rhs in
      guard let lhs = lhs as? V, let rhs = rhs as? V else { return false }
      return lhs == rhs
    }
  }

  var value: any Value {
    _value
  }

  var index: Int {
    _value.index
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    try _value.serialize(into: &serializationContext)
  }

  init(deserializationContext _: inout DeserializationContext) throws {
    fatalError("cannot deserialize type-erased value")
  }

  init(firstValue _: Self?, index _: Int) {
    fatalError("cannot init type-erased value")
  }
}

extension Value {
  func eraseToAny() -> AnyValue {
    if let self = self as? AnyValue {
      self
    } else {
      AnyValue(self)
    }
  }

  func makeValue(relativeTo index: Int) -> Self {
    Self(index: index)
  }
}
