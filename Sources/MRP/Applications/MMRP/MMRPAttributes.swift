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

enum MMRPAttributeType: AttributeType, CaseIterable {
  case serviceRequirement = 1
  case mac = 2

  static var validAttributeTypes: ClosedRange<AttributeType> {
    allCases.first!.rawValue...allCases.last!.rawValue
  }
}

public enum MMRPServiceRequirementValue: UInt8, Value, Equatable, Hashable {
  case allGroups = 0
  case allUnregisteredGroups = 1

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint8: rawValue)
  }

  public init(deserializationContext: inout DeserializationContext) throws {
    let value: UInt8 = try deserializationContext.deserialize()

    guard let value = Self(rawValue: value) else {
      throw MRPError.invalidAttributeValue
    }
    self = value
  }

  public var index: UInt64 {
    UInt64(rawValue)
  }

  public init() {
    self = .allGroups
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    guard let value = Self(rawValue: rawValue + UInt8(index)) else {
      throw MRPError.invalidAttributeValue
    }
    return value
  }
}

struct MMRPMACValue: Value, Equatable, Hashable {
  private let _macAddress: UInt64

  func serialize(into serializationContext: inout SerializationContext) throws {
    precondition((_macAddress & 0xFFFF_0000_0000_0000) == 0)
    serializationContext.serialize(uint32: UInt32(_macAddress >> 16))
    serializationContext.serialize(uint16: UInt16(_macAddress & 0xFFF))
  }

  private init(_macAddress: UInt64) {
    self._macAddress = _macAddress
  }

  init(deserializationContext: inout DeserializationContext) throws {
    let high: UInt32 = try deserializationContext.deserialize()
    let low: UInt16 = try deserializationContext.deserialize()
    _macAddress = UInt64(high << 16) | UInt64(low)
  }

  var index: UInt64 {
    precondition((_macAddress & 0xFFFF_0000_0000_0000) == 0)
    return _macAddress
  }

  init() {
    _macAddress = 0
  }

  func makeValue(relativeTo index: UInt64) throws -> Self {
    Self(_macAddress: _macAddress + UInt64(index))
  }

  var macAddress: EUI48 {
    try! _macAddress.asEUI48()
  }

  init(macAddress: EUI48) {
    _macAddress = UInt64(eui48: macAddress)
  }
}
