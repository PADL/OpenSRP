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
    guard let leaveAllEvent = LeaveAllEvent(rawValue: UInt8(value >> Self.numberOfValuesBits)) else {
      throw MRPError.invalidLeaveAllEvent
    }
    self.leaveAllEvent = leaveAllEvent
    numberOfValues = value & Self.maxNumberOfValues
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    // widen before the shift: leaveAllEvent.rawValue is UInt8, so shifting in UInt8 arithmetic
    // overshifts its 8-bit width and drops the LeaveAll bit (10.8.2.6)
    let value = (UInt16(leaveAllEvent.rawValue) << Self.numberOfValuesBits) |
      (numberOfValues & Self.maxNumberOfValues)
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

    var attributeList = [VectorAttribute<V>]()
    let startCount = input.count

    repeat {
      if let attributeListLength {
        let bytesProcessed = startCount - input.count
        // attributeListLength counts the vectors plus the trailing EndMark; stop once the vectors
        // are consumed and only the EndMark remains
        if bytesProcessed == Int(attributeListLength) - MRPDU.endMarkLength { break }
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

    let endMark: UInt16 = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
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
      // the length covers everything after the AttributeListLength field itself
      let attributeListLength = UInt16(
        serializationContext
          .position - attributeListLengthPosition - Message.attributeListLengthLength
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
        // clause 10.8.3.5: skip unknown attributes if the PDU has a higher protocol version
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

// MARK: - PDU framing sizes and MTU fragmentation (10.8.2)

extension VectorHeader {
  // NumberOfValues is the low 13 bits, LeaveAllEvent the top 3 (10.8.2.6/10.8.2.7).
  static let numberOfValuesBits = 13
  static let maxNumberOfValues = NumberOfValues((1 << numberOfValuesBits) - 1)
  // leaveAllEvent << numberOfValuesBits | numberOfValues, serialized as one UInt16.
  static let serializedLength = 2
}

extension Message {
  static let attributeTypeLength = 1
  static let attributeLengthLength = 1
  static let attributeListLengthLength = 2

  // Octets framing a Message's VectorAttributes: AttributeType, AttributeLength, the optional
  // AttributeListLength, and the trailing EndMark.
  static func framingLength(hasAttributeListLength: Bool) -> Int {
    attributeTypeLength + attributeLengthLength +
      (hasAttributeListLength ? attributeListLengthLength : 0) + MRPDU.endMarkLength
  }
}

extension VectorAttribute {
  // Largest NumberOfValues one vector may carry and still fit `maxLength` serialized octets: a vector
  // costs VectorHeader + firstValue + ceil(N/3) packed events (+ N subtype octets when the type
  // carries them). Also bounded by the 13-bit NumberOfValues field (10.8.2.7).
  static func maxNumberOfValues(
    firstValue: V?,
    hasSubtype: Bool,
    hasAttributeListLength: Bool,
    maxLength: Int
  ) -> Int {
    let firstValueLength = (try? firstValue?.serialized().count) ?? 0
    let fixed = MRPDU.protocolVersionLength + MRPDU.endMarkLength +
      Message.framingLength(hasAttributeListLength: hasAttributeListLength) +
      VectorHeader.serializedLength + firstValueLength
    let budget = maxLength - fixed
    guard budget > 0 else { return 1 }
    // Packed-event octets per N values: ceil(N/3) three-packed AttributeEvents, plus ceil(N/4)
    // four-packed subtype octets when the type carries a subtype. Invert conservatively for the
    // largest N within budget: without a subtype ceil(N/3) <= budget gives N <= 3*budget exactly;
    // with a subtype (N+2)/3 + (N+3)/4 <= budget gives N <= (12*budget - 17)/7 (17 = 4*2 + 3*3).
    let maxN = hasSubtype ? (12 * budget - 17) / 7 : 3 * budget
    return max(1, min(Int(VectorHeader.maxNumberOfValues), maxN))
  }
}

extension MRPDU {
  static let protocolVersionLength = 1
  static let endMarkLength = 2 // a Message EndMark and the MRPDU EndMark are each one UInt16
}

extension Array where Element == Message {
  // 10.8.2.8 c): split these messages into MRPDUs that each serialize within `maxLength` octets,
  // packing whole VectorAttributes greedily and emitting successive PDUs (frames) for the remainder.
  // A serialized MRPDU is exactly the PDU framing plus, per message, the message framing plus each
  // vector's own length, so the running size is tracked without re-serializing the prefix. A vector
  // that alone exceeds `maxLength` is emitted on its own (best-effort) and reported via `oversize`;
  // callers cap vector size up front with VectorAttribute.maxNumberOfValues.
  func fragmentedIntoPDUs(
    protocolVersion: ProtocolVersion,
    hasAttributeListLength: Bool,
    maxLength: Int,
    oversize: (Int) -> Void = { _ in }
  ) throws -> [MRPDU] {
    let pduFraming = MRPDU.protocolVersionLength + MRPDU.endMarkLength
    let msgFraming = Message.framingLength(hasAttributeListLength: hasAttributeListLength)
    // Exact serialized length without re-serializing the packed events (bridge.tx serializes them
    // again): VectorHeader + firstValue + the three-packed and optional four-packed subtype octets.
    func vectorLength(_ vector: VectorAttribute<AnyValue>) throws -> Int {
      VectorHeader.serializedLength + (try vector.firstValue.serialized().count) +
        vector.threePackedEvents.count + (vector.fourPackedEvents?.count ?? 0)
    }

    var pdus = [MRPDU]()
    var current = [Message]()
    var currentBytes = pduFraming
    for message in self {
      var vectors = [VectorAttribute<AnyValue>]()
      var headerCounted = false
      for vector in message.attributeList {
        let vBytes = try vectorLength(vector)
        let delta = vBytes + (headerCounted ? 0 : msgFraming)
        if currentBytes + delta > maxLength, !(current.isEmpty && vectors.isEmpty) {
          if !vectors.isEmpty {
            current.append(Message(attributeType: message.attributeType, attributeList: vectors))
            vectors.removeAll()
          }
          pdus.append(MRPDU(protocolVersion: protocolVersion, messages: current))
          current.removeAll()
          currentBytes = pduFraming
          headerCounted = false
        }
        if pduFraming + msgFraming + vBytes > maxLength { oversize(vBytes) }
        if !headerCounted { currentBytes += msgFraming; headerCounted = true }
        currentBytes += vBytes
        vectors.append(vector)
      }
      if !vectors.isEmpty {
        current.append(Message(attributeType: message.attributeType, attributeList: vectors))
      }
    }
    if !current.isEmpty {
      pdus.append(MRPDU(protocolVersion: protocolVersion, messages: current))
    }
    return pdus
  }
}
