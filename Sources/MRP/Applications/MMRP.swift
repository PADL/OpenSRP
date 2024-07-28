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

struct MMRPValue: Value, Equatable, Hashable {
  private let _value: UInt64

  func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint32: UInt32(_value >> 16))
    serializationContext.serialize(uint16: UInt16(_value & 0xFFF))
  }

  init(deserializationContext: inout DeserializationContext) throws {
    let high: UInt32 = try deserializationContext.deserialize()
    let low: UInt16 = try deserializationContext.deserialize()
    _value = UInt64(high << 16) | UInt64(low)
  }

  var index: Int {
    precondition(_value <= 0xFFFF_FFFF_FFFF)
    return Int(_value)
  }

  init(firstValue: MMRPValue?, index: Int) {
    _value = (firstValue?._value ?? 0) + UInt64(index)
  }

  var macAddress: EUI48 {
    (
      UInt8((_value >> 40) & 0xFF),
      UInt8((_value >> 32) & 0xFF),
      UInt8((_value >> 24) & 0xFF),
      UInt8((_value >> 16) & 0xFF),
      UInt8((_value >> 8) & 0xFF),
      UInt8((_value >> 0) & 0xFF)
    )
  }
}
