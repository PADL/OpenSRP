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

import BinaryParsing
import IEEE802

public protocol Value: SerDes, Equatable {
  var index: UInt64 { get }

  func makeValue(relativeTo index: UInt64) throws -> Self
}

struct AnyValue: Value, Equatable, CustomStringConvertible {
  static func == (lhs: AnyValue, rhs: AnyValue) -> Bool {
    lhs._value._isEqual(to: rhs._value)
  }

  private let _value: any Value

  init<V: Value>(_ value: V) {
    _value = value
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

  func makeValue(relativeTo index: UInt64) throws -> Self {
    Self(try _value.makeValue(relativeTo: index))
  }

  init(parsing _: inout ParserSpan) throws {
    fatalError("cannot deserialize type-erased value")
  }

  var description: String {
    String(describing: _value)
  }
}

extension Value {
  fileprivate func _isEqual(to other: any Value) -> Bool {
    guard let other = other as? Self else { return false }
    return self == other
  }

  func eraseToAny() -> AnyValue {
    if let self = self as? AnyValue {
      self
    } else {
      AnyValue(self)
    }
  }
}
