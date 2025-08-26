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

import Algorithms
import IEEE802

public typealias ProtocolVersion = UInt8

struct ThreePackedEvents: Equatable, CustomStringConvertible {
  let value: UInt8

  init(_ value: UInt8) {
    self.value = value
  }

  init(_ tuple: (UInt8, UInt8, UInt8)) {
    value = ((tuple.0 * 6) + tuple.1) * 6 + tuple.2
  }

  var tuple: (UInt8, UInt8, UInt8) {
    var value = value
    var r: (UInt8, UInt8, UInt8)
    r.0 = value / (6 * 6)
    value -= r.0 * (6 * 6)
    r.1 = value / 6
    value -= r.1 * 6
    r.2 = value
    return r
  }

  var description: String {
    "ThreePackedEvents(tuple: \(tuple))"
  }

  static func chunked(_ values: [UInt8]) -> [ThreePackedEvents] {
    let values = values.chunks(ofCount: 3)
    return values.map {
      ThreePackedEvents(($0[0], $0[safe: 1] ?? 0, $0[safe: 2] ?? 0))
    }
  }
}

struct FourPackedEvents: Equatable, CustomStringConvertible {
  let value: UInt8

  init(_ value: UInt8) {
    self.value = value
  }

  init(_ tuple: (UInt8, UInt8, UInt8, UInt8)) {
    value = tuple.0 * 64 + tuple.1 * 16 + tuple.2 * 4 + tuple.3
  }

  var tuple: (UInt8, UInt8, UInt8, UInt8) {
    var value = value
    var r: (UInt8, UInt8, UInt8, UInt8)
    r.0 = value / 64
    value -= r.0 * 64
    r.1 = value / 16
    value -= r.1 * 16
    r.2 = value / 4
    value -= r.2 * 4
    r.3 = value
    return r
  }

  var description: String {
    "FourPackedEvents(tuple: \(tuple))"
  }

  static func chunked(_ values: [UInt8]) -> [FourPackedEvents] {
    let values = values.chunks(ofCount: 4)
    return values.map {
      FourPackedEvents(($0[0], $0[safe: 1] ?? 0, $0[safe: 2] ?? 0, $0[safe: 3] ?? 0))
    }
  }
}

typealias NumberOfValues = UInt16 // Number of events encoded in the vector

let EndMark: UInt16 = 0

enum LeaveAllEvent: UInt8 {
  case NullLeaveAllEvent = 0
  case LeaveAll = 1
}

struct VectorHeader: Sendable, Equatable, Hashable, SerDes {
  let leaveAllEvent: LeaveAllEvent
  let numberOfValues: NumberOfValues

  init(leaveAllEvent: LeaveAllEvent, numberOfValues: NumberOfValues) {
    self.leaveAllEvent = leaveAllEvent
    self.numberOfValues = numberOfValues
  }

  init(deserializationContext: inout DeserializationContext) throws {
    let value: UInt16 = try deserializationContext.deserialize()
    guard let leaveAllEvent = LeaveAllEvent(rawValue: UInt8(value >> 13)) else {
      throw MRPError.invalidLeaveAllEvent
    }
    self.leaveAllEvent = leaveAllEvent
    numberOfValues = value & 0x1FFF
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    let value = UInt16(leaveAllEvent.rawValue << 13) | UInt16(numberOfValues & 0x1FFF)
    serializationContext.serialize(uint16: value)
  }
}

public typealias AttributeType = UInt8
typealias AttributeLength = UInt8
typealias AttributeListLength = UInt16

struct VectorAttribute<V: Value>: Sendable, Equatable {
  static func == (lhs: VectorAttribute<V>, rhs: VectorAttribute<V>) -> Bool {
    guard lhs.vectorHeader == rhs.vectorHeader && lhs.threePackedEvents == rhs
      .threePackedEvents && lhs.fourPackedEvents == rhs.fourPackedEvents
    else {
      return false
    }

    return AnyValue(lhs.firstValue) == AnyValue(rhs.firstValue)
  }

  private let vectorHeader: VectorHeader

  // f) If the number of AttributeEvent values is zero, FirstValue is ignored
  // and the value is skipped. However, FirstValue is still present, and of
  // the correct length, in octets, as specified by the AttributeLength field
  // (10.8.2.3) for the Attribute to which the message applies.

  let firstValue: V
  let threePackedEvents: [ThreePackedEvents]
  let fourPackedEvents: [FourPackedEvents]?

  var leaveAllEvent: LeaveAllEvent { vectorHeader.leaveAllEvent }
  var numberOfValues: NumberOfValues { vectorHeader.numberOfValues }

  var attributeEvents: [AttributeEvent] {
    get throws {
      try threePackedEvents.flatMap {
        let tuple = $0.tuple
        return [tuple.0, tuple.1, tuple.2]
      }.map {
        guard let attributeEvent = AttributeEvent(rawValue: $0) else {
          throw MRPError.unknownAttributeEvent
        }
        return attributeEvent
      }
    }
  }

  var applicationEvents: [AttributeSubtype]? {
    guard let fourPackedEvents else { return nil }
    return fourPackedEvents.flatMap {
      let tuple = $0.tuple
      return [tuple.0, tuple.1, tuple.2, tuple.3]
    }
  }

  private init(
    vectorHeader: VectorHeader,
    firstValue: V,
    threePackedEvents: [ThreePackedEvents],
    fourPackedEvents: [FourPackedEvents]?
  ) {
    self.vectorHeader = vectorHeader
    self.firstValue = firstValue
    self.threePackedEvents = threePackedEvents
    self.fourPackedEvents = fourPackedEvents
  }

  private init(
    leaveAllEvent: LeaveAllEvent,
    numberOfValues: NumberOfValues,
    firstValue: V,
    threePackedEvents: [ThreePackedEvents],
    fourPackedEvents: [FourPackedEvents]?
  ) {
    self.init(
      vectorHeader: VectorHeader(
        leaveAllEvent: leaveAllEvent,
        numberOfValues: numberOfValues
      ),
      firstValue: firstValue,
      threePackedEvents: threePackedEvents,
      fourPackedEvents: fourPackedEvents
    )
  }

  init(
    vectorHeader: VectorHeader,
    firstValue: V,
    threePackedEvents: [UInt8],
    fourPackedEvents: [UInt8]?
  ) {
    let _fourPackedEvents: [FourPackedEvents]? = if let fourPackedEvents {
      fourPackedEvents.map { FourPackedEvents($0) }
    } else {
      nil
    }
    self.init(
      vectorHeader: vectorHeader,
      firstValue: firstValue,
      threePackedEvents: threePackedEvents.map { ThreePackedEvents($0) },
      fourPackedEvents: _fourPackedEvents
    )
  }

  init(
    leaveAllEvent: LeaveAllEvent,
    numberOfValues: NumberOfValues,
    firstValue: V,
    threePackedEvents: [UInt8],
    fourPackedEvents: [UInt8]?
  ) {
    self.init(
      vectorHeader: VectorHeader(
        leaveAllEvent: leaveAllEvent,
        numberOfValues: numberOfValues
      ),
      firstValue: firstValue,
      threePackedEvents: threePackedEvents,
      fourPackedEvents: fourPackedEvents
    )
  }

  init(
    leaveAllEvent: LeaveAllEvent,
    firstValue: V,
    attributeEvents: [AttributeEvent],
    applicationEvents: [AttributeSubtype]?
  ) {
    let fourPackedEvents: [FourPackedEvents]?
    if let applicationEvents {
      precondition(applicationEvents.count == attributeEvents.count)
      fourPackedEvents = FourPackedEvents.chunked(applicationEvents)
    } else {
      fourPackedEvents = nil
    }
    self.init(
      leaveAllEvent: leaveAllEvent,
      numberOfValues: UInt16(attributeEvents.count),
      firstValue: firstValue,
      threePackedEvents: ThreePackedEvents.chunked(attributeEvents.map(\.rawValue)),
      fourPackedEvents: fourPackedEvents
    )
  }

  init(
    attributeType: AttributeType,
    attributeLength: AttributeLength,
    deserializationContext: inout DeserializationContext,
    application: some Application
  ) throws where V == AnyValue {
    let vectorHeader = try VectorHeader(deserializationContext: &deserializationContext)
    try deserializationContext.assertRemainingLength(isAtLeast: Int(attributeLength))
    let firstValue = try AnyValue(application.deserialize(
      attributeOfType: attributeType,
      from: &deserializationContext
    ))

    let numberOfValueOctets = Int.ceil(Int(vectorHeader.numberOfValues), 3)
    let threePacketEvents = try Array(
      deserializationContext
        .deserialize(count: numberOfValueOctets)
    )

    let fourPackedEvents: [UInt8]?

    if application.hasAttributeSubtype(for: attributeType) {
      let numberOfValueOctets = Int.ceil(Int(vectorHeader.numberOfValues), 4)
      fourPackedEvents = try Array(deserializationContext.deserialize(count: numberOfValueOctets))
    } else {
      fourPackedEvents = nil
    }
    self.init(
      vectorHeader: vectorHeader,
      firstValue: firstValue,
      threePackedEvents: threePacketEvents,
      fourPackedEvents: fourPackedEvents
    )
  }

  func serialize(into serializationContext: inout SerializationContext) throws
    -> AttributeLength
  {
    try vectorHeader.serialize(into: &serializationContext)
    let attributeLength: AttributeLength
    let oldPosition = serializationContext.position
    try firstValue.serialize(into: &serializationContext)
    attributeLength = AttributeLength(serializationContext.position - oldPosition)
    serializationContext.serialize(threePackedEvents.map(\.value))
    if let fourPackedEvents {
      serializationContext.serialize(fourPackedEvents.map(\.value))
    }
    return attributeLength
  }
}

struct Message {
  typealias V = AnyValue

  let attributeType: AttributeType
  let attributeList: [VectorAttribute<V>]

  init(attributeType: AttributeType, attributeList: [VectorAttribute<V>]) {
    self.attributeType = attributeType
    self.attributeList = attributeList
  }

  init(
    deserializationContext: inout DeserializationContext,
    application: some Application
  ) throws {
    attributeType = try deserializationContext.deserialize()

    // attributeLength is the length, in octets, of an attribute's firstValue
    let attributeLength: AttributeLength = try deserializationContext.deserialize()

    // attributeListLength is optional and is the length, in octets, of the entire attribute list
    // this can account for variable length attributes
    var attributeListLength: AttributeListLength?
    var attributeListPosition = 0

    if application.hasAttributeListLength {
      attributeListLength = try deserializationContext.deserialize()
      guard attributeListLength! <= deserializationContext.bytesRemaining
      else { throw MRPError.badPduLength }
      attributeListPosition = deserializationContext.position
    }

    var attributeList = [VectorAttribute<V>]()

    repeat {
      if let attributeListLength {
        if deserializationContext
          .position == attributeListPosition + Int(attributeListLength) - 2 { break }
      } else {
        let mark: UInt16 = try deserializationContext.peek()
        if mark == EndMark { break }
      }

      let vectorAttribute = try VectorAttribute<V>(
        attributeType: attributeType,
        attributeLength: attributeLength,
        deserializationContext: &deserializationContext,
        application: application
      )
      attributeList.append(vectorAttribute)
    } while deserializationContext.position < deserializationContext.count

    let endMark: UInt16 = try deserializationContext.deserialize()
    guard endMark == EndMark else {
      throw MRPError.badPduEndMark
    }
    self.attributeList = attributeList
  }

  func serialize(
    into serializationContext: inout SerializationContext,
    application: some Application
  ) throws {
    serializationContext.serialize(uint8: attributeType)
    let attributeLengthPosition = serializationContext.position
    var attributeLength = AttributeLength(0)
    serializationContext.serialize(uint8: attributeLength)
    var attributeListLengthPosition: Int?
    if application.hasAttributeListLength {
      attributeListLengthPosition = serializationContext.position
      serializationContext.serialize(uint16: 0)
    }
    for attribute in attributeList {
      try attributeLength = attribute.serialize(into: &serializationContext)
    }
    serializationContext.serialize(uint16: EndMark)
    serializationContext.serialize(uint8: attributeLength, at: attributeLengthPosition)
    if let attributeListLengthPosition {
      let attributeListLength = UInt16(
        serializationContext
          .position - attributeListLengthPosition - 2
      )
      serializationContext.serialize(uint16: attributeListLength, at: attributeListLengthPosition)
    }
  }
}

struct MRPDU {
  let protocolVersion: ProtocolVersion
  let messages: [Message]

  init(protocolVersion: ProtocolVersion, messages: [Message]) {
    self.protocolVersion = protocolVersion
    self.messages = messages
  }

  init(
    deserializationContext: inout DeserializationContext,
    application: some Application
  ) throws {
    protocolVersion = try deserializationContext.deserialize()
    var messages = [Message]()
    repeat {
      let mark: UInt16 = try deserializationContext.peek()
      if mark == EndMark {
        break
      }
      do {
        try messages.append(Message(
          deserializationContext: &deserializationContext,
          application: application
        ))
      } catch let error as MRPError {
        // clause 10.8.3.5: skip unknown attributes if PDU has a higher protocol version
        guard protocolVersion > application.protocolVersion,
              error == .unknownAttributeType || error == .unknownAttributeEvent
        else {
          throw error
        }
      }
    } while deserializationContext.position < deserializationContext.count
    self.messages = messages
  }

  func serialize(
    into serializationContext: inout SerializationContext,
    application: some Application
  ) throws {
    serializationContext.serialize(uint8: protocolVersion)
    for message in messages {
      try message.serialize(into: &serializationContext, application: application)
    }
    serializationContext.serialize(uint16: EndMark)
  }
}
