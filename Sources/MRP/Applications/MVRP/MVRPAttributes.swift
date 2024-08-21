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

enum MVRPAttributeType: AttributeType, CaseIterable {
  case vid = 1

  static var validAttributeTypes: ClosedRange<AttributeType> {
    allCases.first!.rawValue...allCases.last!.rawValue
  }
}

public typealias MVRPVIDValue = VLAN

extension VLAN: Value {
  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint16: vid)
  }

  public init(deserializationContext: inout DeserializationContext) throws {
    let newVid: UInt16 = try deserializationContext.deserialize()
    guard newVid <= 0xFFF else { throw MRPError.invalidAttributeValue }
    self.init(vid: newVid)
  }

  public var index: UInt64 {
    UInt64(vid)
  }

  public init() {
    self.init(vid: 0)
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    let newVid = UInt64(vid) + index
    guard newVid <= 0xFFF else { throw MRPError.invalidAttributeValue }
    return Self(vid: UInt16(newVid))
  }
}
