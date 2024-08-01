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
    case .Mt:
      .rMt
    case .In:
      .rIn
    case .JoinMt:
      .rJoinMt
    case .JoinIn:
      .rJoinIn
    case .Lv:
      .rLv
    case .New:
      .rNew
    }
  }
}

struct OperationalStatistics {
  var failureToRegisterCount: Int
}

typealias EUI48 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

typealias MAPContextIdentifier = Int
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
