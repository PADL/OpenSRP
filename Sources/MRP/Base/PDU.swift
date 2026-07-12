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
import BinaryParsing
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
    values.chunks(ofCount: 3).map { chunk in
      let array = Array(chunk, multiple: 3, with: 0)
      return ThreePackedEvents((array[0], array[1], array[2]))
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
    values.chunks(ofCount: 4).map { chunk in
      let array = Array(chunk, multiple: 4, with: 0)
      return FourPackedEvents((array[0], array[1], array[2], array[3]))
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

  init(parsing input: inout ParserSpan) throws {
    let value: UInt16 = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    guard let leaveAllEvent = LeaveAllEvent(rawValue: UInt8(value >> 13)) else {
      throw MRPError.invalidLeaveAllEvent
    }
    self.leaveAllEvent = leaveAllEvent
    numberOfValues = value & 0x1FFF
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    // widen before the shift: leaveAllEvent.rawValue is UInt8, so `rawValue << 13` in UInt8
    // arithmetic overshifts its 8-bit width and drops the LeaveAll bit (10.8.2.6)
    let value = (UInt16(leaveAllEvent.rawValue) << 13) | (numberOfValues & 0x1FFF)
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
      }
      .prefix(Int(numberOfValues))
      .map {
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
    parsing input: inout ParserSpan,
    application: some Application
  ) throws where V == AnyValue {
    let vectorHeader = try VectorHeader(parsing: &input)
    guard input.count >= Int(attributeLength) else {
      throw MRPError.badPduLength
    }
    let firstValueStart = input.count
    let firstValue = try AnyValue(application.deserialize(
      attributeOfType: attributeType,
      from: &input
    ))
    // attributeLength must equal the firstValue octets actually consumed: a shorter
    // length over-reads into the packed events, a longer one leaves stray octets.
    guard firstValueStart - input.count == Int(attributeLength) else {
      throw MRPError.badPduLength
    }

    let numberOfValueOctets = Int.ceil(Int(vectorHeader.numberOfValues), 3)
    let threePacketEvents = try Array(parsing: &input, byteCount: numberOfValueOctets)

    let fourPackedEvents: [UInt8]?

    if application.hasAttributeSubtype(for: attributeType) {
      let numberOfValueOctets = Int.ceil(Int(vectorHeader.numberOfValues), 4)
      fourPackedEvents = try Array(parsing: &input, byteCount: numberOfValueOctets)
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
    parsing input: inout ParserSpan,
    application: some Application
  ) throws {
    attributeType = try UInt8(parsing: &input)

    // attributeLength is the length, in octets, of an attribute's firstValue
    let attributeLength: AttributeLength = try UInt8(parsing: &input)

    // attributeListLength is optional and is the length, in octets, of the entire attribute list
    // this can account for variable length attributes
    var attributeListLength: AttributeListLength?

    if application.hasAttributeListLength {
      attributeListLength = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      guard attributeListLength! <= input.count
      else { throw MRPError.badPduLength }
    }

    // 10.8.3.5(c)1): an unrecognized AttributeType is discarded by skipping its VectorAttributes to
    // the EndMark. We realign input past that EndMark and then throw: the mutated span is written
    // back on the throw, so the caller -- which knows the PDU's protocol version -- resumes at the
    // next Message (higher version) or drops the tail.
    if !application.validAttributeTypes.contains(attributeType) {
      try Message.skipAttributeList(
        parsing: &input,
        attributeLength: attributeLength,
        attributeListLength: attributeListLength
      )
      throw MRPError.unknownAttributeType
    }

    var attributeList = [VectorAttribute<V>]()
    let startCount = input.count

    repeat {
      // 10.8.3.1: the physical end of the PDU is taken to be an EndMark, so fewer than two octets
      // remaining terminates the attribute list without an explicit EndMark.
      guard input.count >= 2 else { break }
      if let attributeListLength {
        let bytesProcessed = startCount - input.count
        if bytesProcessed == Int(attributeListLength) - 2 { break }
      } else {
        // Peek at next 2 bytes to check for EndMark
        var peekSpan = ParserSpan(input.bytes)
        let mark: UInt16 = try UInt16(parsing: &peekSpan, storedAsBigEndian: UInt16.self)
        if mark == EndMark { break }
      }

      let vectorAttribute = try VectorAttribute<V>(
        attributeType: attributeType,
        attributeLength: attributeLength,
        parsing: &input,
        application: application
      )
      attributeList.append(vectorAttribute)
    } while input.count > 0

    // Consume the explicit EndMark when present. The end of the PDU is itself an EndMark
    // (10.8.3.1),
    // so an attribute list that runs exactly to the frame boundary is valid and needs no trailing
    // 0x0000; a lone remaining octet is a truncated tail, rejected so the caller discards from here
    // (Avnu ProAV Bridge §8.1).
    if input.count >= 2 {
      let endMark: UInt16 = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      guard endMark == EndMark else {
        throw MRPError.badPduEndMark
      }
    } else if input.count == 1 {
      throw MRPError.badPduLength
    }
    self.attributeList = attributeList
  }

  // 10.8.3.5: advance past an unrecognized-AttributeType Message's VectorAttributes and EndMark
  // without decoding them. Each VectorAttribute is VectorHeader(2) + firstValue(attributeLength) +
  // ceil(numberOfValues/3) ThreePackedEvents; an unknown type carries no AttributeSubtype.
  private static func skipAttributeList(
    parsing input: inout ParserSpan,
    attributeLength: AttributeLength,
    attributeListLength: AttributeListLength?
  ) throws {
    let startCount = input.count
    repeat {
      if let attributeListLength {
        if startCount - input.count == Int(attributeListLength) - 2 { break }
      } else {
        var peekSpan = ParserSpan(input.bytes)
        let mark = try UInt16(parsing: &peekSpan, storedAsBigEndian: UInt16.self)
        if mark == EndMark { break }
      }
      let vectorHeader = try VectorHeader(parsing: &input)
      let bytesToSkip = Int(attributeLength) + Int.ceil(Int(vectorHeader.numberOfValues), 3)
      guard input.count >= bytesToSkip else { throw MRPError.badPduLength }
      try input.seek(toRelativeOffset: bytesToSkip)
    } while input.count > 0
    let endMark: UInt16 = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    guard endMark == EndMark else {
      throw MRPError.badPduEndMark
    }
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
    parsing input: inout ParserSpan,
    application: some Application
  ) throws {
    protocolVersion = try UInt8(parsing: &input)
    var messages = [Message]()
    while input.count > 0 {
      // Peek at the next 2 octets for the EndMark. Fewer than 2 octets remaining means a
      // truncated/badly-formed tail: stop and keep the messages parsed so far. Avnu ProAV Bridge
      // §8.1 — upon receipt of a badly formed MRPDU a Bridge may act on the contents preceding the
      // corrupted field and shall discard everything that follows it.
      var peekSpan = ParserSpan(input.bytes)
      guard let mark = try? UInt16(parsing: &peekSpan, storedAsBigEndian: UInt16.self),
            mark != EndMark else { break }
      do {
        try messages.append(Message(parsing: &input, application: application))
      } catch let error as MRPError where protocolVersion > application.protocolVersion &&
        (error == .unknownAttributeType || error == .unknownAttributeEvent)
      {
        // clause 10.8.3.5: skip unknown attributes if the PDU has a higher protocol version.
        // Message.init has already advanced input past the unknown Message's EndMark (the mutated
        // span survives the throw), so we resume cleanly at the next Message.
        continue
      } catch {
        // a corrupted or truncated field (a structural MRPError, or the parser running off the
        // end of the buffer): discard from here on, keeping the valid prefix (Avnu §8.1).
        break
      }
    }
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
