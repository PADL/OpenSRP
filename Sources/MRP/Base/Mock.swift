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

import Logging

struct MockValue: Value {
  let _index: UInt32

  var index: Int { Int(_index) }

  init() { _index = 0 }
  init(firstValue: MockValue? = nil, index: Int) {
    _index = firstValue?._index ?? 0 + UInt32(index)
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint64: _index)
  }

  init(deserializationContext: inout DeserializationContext) throws {
    _index = try deserializationContext.deserialize()
  }
}

final class MockApplication<P: Port>: BaseApplication, Sendable where P == P {
  let _delegate: (any ApplicationDelegate<P>)? = nil

  func set(logger: Logger) {
    _logger.withCriticalRegion { $0 = logger }
  }

  var validAttributeTypes: ClosedRange<AttributeType> { 0...0 }
  var groupMacAddress: EUI48 { EUI48(0, 0, 0, 0, 0, 0) }
  var etherType: UInt16 { 0xFFFF }
  var protocolVersion: ProtocolVersion { 1 }

  let _mad: Weak<Controller<P>>
  let _participants =
    ManagedCriticalState<[MAPContextIdentifier: Set<Participant<MockApplication<P>>>]>([:])
  let _logger = ManagedCriticalState<Logger?>(nil)

  init(owner: Controller<P>) {
    _mad = Weak(owner)
  }

  func deserialize(
    attributeOfType _: AttributeType,
    from deserializationContext: inout DeserializationContext
  ) throws -> any Value {
    try MockValue(deserializationContext: &deserializationContext)
  }

  func makeValue(for _: AttributeType, at index: Int) throws -> any Value {
    MockValue(index: index)
  }

  func packedEventsType(for attributeType: AttributeType) throws -> PackedEventsType {
    guard attributeType == 0 else { throw MRPError.attributeNotFound }
    return .threePackedType
  }

  func administrativeControl(for attributeType: AttributeType) throws -> AdministrativeControl {
    guard attributeType == 0 else { throw MRPError.attributeNotFound }
    return .normalParticipant
  }
}
