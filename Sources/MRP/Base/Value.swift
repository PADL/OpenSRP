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

// c) The Message contains a VectorAttribute (10.8.1.2) where the range defined
// by the FirstValue and NumberOfValues includes the attribute value associated
// with the state machine.

public protocol Value: SerDes, Equatable {
  var index: UInt64 { get }

  init(firstValue: Self?, index: UInt64) throws
}

extension Value {
  init(index: UInt64) throws {
    try self.init(firstValue: nil, index: index)
  }
}

struct AnyValue: Value, Equatable, CustomStringConvertible {
  static func == (lhs: AnyValue, rhs: AnyValue) -> Bool {
    guard let lhs = try? lhs.serialized(), let rhs = try? rhs.serialized() else {
      return false
    }
    return lhs == rhs
  }

  private let _value: any Value
  private let _isEqual: @Sendable (_: any Value, _: AnyValue)
    -> Bool

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

  var index: UInt64 {
    _value.index
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    try _value.serialize(into: &serializationContext)
  }

  init(deserializationContext _: inout DeserializationContext) throws {
    fatalError("cannot deserialize type-erased value")
  }

  init(firstValue _: Self?, index _: UInt64) {
    fatalError("cannot init type-erased value")
  }

  var description: String {
    String(describing: _value)
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

  func makeValue(relativeTo index: UInt64) throws -> Self {
    try Self(firstValue: self, index: index)
  }
}
