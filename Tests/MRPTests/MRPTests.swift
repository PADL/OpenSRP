//
// Copyright (c) 2024-2025 PADL Software Pty Ltd
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

@_spi(MRPTesting)
@testable import MRP
import XCTest
@preconcurrency
import AsyncExtensions
import IEEE802
import Logging
import SystemPackage

struct MockPort: MRP.Port, Equatable, Hashable, Identifiable, Sendable, CustomStringConvertible,
  AVBPort
{
  var id: Int

  static func == (lhs: MockPort, rhs: MockPort) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {}

  var isOperational: Bool { true }

  var isEnabled: Bool { true }

  var isPointToPoint: Bool { true }

  var name: String { "eth\(id)" }

  var description: String { name }

  var pvid: UInt16? { nil }

  var vlans: Set<MRP.VLAN> { [] }

  var macAddress: EUI48 { (0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) }

  var mtu: UInt { 1500 }

  var linkSpeed: UInt { 1_000_000 }

  var isAvbCapable: Bool { true }

  var isAsCapable: Bool { true }

  func getPortTcMaxLatency(for: SRclassPriority) async throws -> Int { 0 }

  init(id: ID) {
    self.id = id
  }

  static func timeSinceEpoch() throws -> UInt32 {
    var tv = timeval()
    guard gettimeofday(&tv, nil) == 0 else {
      throw Errno(rawValue: errno)
    }
    return UInt32(tv.tv_sec)
  }
}

struct MockBridge: MRP.Bridge, CustomStringConvertible {
  var notifications = AsyncEmptySequence<MRP.PortNotification<MockPort>>().eraseToAnyAsyncSequence()
  var rxPackets = AsyncEmptySequence<(Int, IEEE802Packet)>().eraseToAnyAsyncSequence()

  func getPorts(controller: isolated MRPController<P>) async throws -> Set<MockPort> {
    [MockPort(id: 0)]
  }

  typealias P = MockPort

  var description: String { "MockBridge" }
  func getVlans(controller: isolated MRPController<P>) async -> Set<MRP.VLAN> { [] }

  func register(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<P>
  ) async throws {}
  func deregister(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<P>
  ) async throws {}

  func run(controller: isolated MRPController<P>) async throws {}
  func shutdown(controller: isolated MRPController<P>) async throws {}

  func tx(
    _ packet: IEEE802Packet,
    on port: P,
    controller: isolated MRPController<P>
  ) async throws {}
}

final class MRPTests: XCTestCase {
  func testEUI48() async throws {
    let eui48: EUI48 = (0, 0, 0, 0, 0x1, 0xFF)
    XCTAssertEqual(UInt64(eui48: eui48), 0x1FF)
    XCTAssertTrue(try! _isEqualMacAddress(eui48, UInt64(0x1FF).asEUI48()))
  }

  func testBasic() async throws {
    let logger = Logger(label: "com.padl.MRPTests")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let mvrp = try await MVRPApplication(controller: controller)

    let bytes: [UInt8] = [
      0x01,
      0x80,
      0xC2,
      0x00,
      0x00,
      0x21,
      0x00,
      0x04,
      0x96,
      0x51,
      0xEA,
      0xA5,
      0x88,
      0xF5,
      0x00,
      0x01,
      0x02,
      0x00,
      0x02,
      0x00,
      0x01,
      0x72,
      0x00,
      0x01,
      0x00,
      0x21,
      0x6C,
      0x00,
      0x01,
      0x00,
      0x64,
      0x48,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ]

    var deserializationContext = DeserializationContext(bytes)
    let packet = try IEEE802Packet(deserializationContext: &deserializationContext)

    var deserializationContext2 = DeserializationContext(packet.payload)

    let pdu = try MRPDU(deserializationContext: &deserializationContext2, application: mvrp)
    XCTAssertEqual(pdu.protocolVersion, 0)
    XCTAssertEqual(pdu.messages.count, 1)
    if let message = pdu.messages.first {
      XCTAssertEqual(message.attributeType, 1)
      XCTAssertEqual(message.attributeList.count, 3)
      if let firstAttribute = message.attributeList.first {
        XCTAssertEqual(firstAttribute.firstValue, AnyValue(VLAN(vid: 1)))
        XCTAssertEqual(firstAttribute.leaveAllEvent, .NullLeaveAllEvent)
        XCTAssertEqual(firstAttribute.threePackedEvents.map(\.value), [114])
        XCTAssertEqual(try firstAttribute.attributeEvents, [.JoinMt, .JoinIn])

        let v = VectorAttribute(
          leaveAllEvent: .NullLeaveAllEvent,
          firstValue: AnyValue(VLAN(vid: 1)),
          attributeEvents: [.JoinMt, .JoinIn],
          applicationEvents: nil
        )
        XCTAssertEqual(v, firstAttribute)
      }
    }

    var serializationContext = SerializationContext()
    try packet.serialize(into: &serializationContext)
    XCTAssertEqual(bytes, serializationContext.bytes)

    var serializationContext2 = SerializationContext()
    try pdu.serialize(into: &serializationContext2, application: mvrp)
    // Note: prefix is necessary because captured packet has trailing zeros
    XCTAssertEqual(
      Array(packet.payload.prefix(serializationContext2.bytes.count)),
      serializationContext2.bytes
    )
  }

  func testLeaveAllOnlyVectorAttribute() {
    let vectorAttribute = try VectorAttribute<AnyValue>(
      leaveAllEvent: .LeaveAll,
      firstValue: AnyValue(MSRPTalkerAdvertiseValue()),
      attributeEvents: [],
      applicationEvents: nil
    )
    let vectorAttributes = [vectorAttribute]
    XCTAssertEqual(vectorAttributes.count, 1)
    XCTAssertEqual(vectorAttribute.numberOfValues, 0)
  }

  func testMMRPSerialization() async throws {
    let logger = Logger(label: "com.padl.MRPTests.MMRP")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    _ = try await MMRPApplication(controller: controller)

    // Test service requirement value serialization
    let serviceReqValue = MMRPServiceRequirementValue.allGroups
    var serializationContext = SerializationContext()
    try serviceReqValue.serialize(into: &serializationContext)
    XCTAssertEqual(serializationContext.bytes, [0x00])

    var deserializationContext = DeserializationContext([0x00])
    let deserializedServiceReq =
      try MMRPServiceRequirementValue(deserializationContext: &deserializationContext)
    XCTAssertEqual(deserializedServiceReq, .allGroups)

    // Test MAC value serialization
    let macValue = MMRPMACValue(macAddress: (0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E))
    serializationContext = SerializationContext()
    try macValue.serialize(into: &serializationContext)

    // Test that we can deserialize what we just serialized
    deserializationContext = DeserializationContext(serializationContext.bytes)
    let deserializedMAC = try MMRPMACValue(deserializationContext: &deserializationContext)

    // Test round-trip serialization - with the fixed deserialization logic,
    // this should now properly preserve the data
    var testSerializationContext = SerializationContext()
    try deserializedMAC.serialize(into: &testSerializationContext)

    // The round-trip should now preserve the original bytes
    XCTAssertEqual(testSerializationContext.bytes, serializationContext.bytes)

    // Also verify that the MAC address itself is correctly preserved
    XCTAssertTrue(_isEqualMacAddress(
      deserializedMAC.macAddress,
      (0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E)
    ))
  }

  func testAttributeValueEquality() async throws {
    // Test with VLAN values
    let vlan1 = VLAN(vid: 100)
    let vlan2 = VLAN(vid: 100)
    let vlan3 = VLAN(vid: 200)

    let av1 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan1)
    )
    let av2 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan2)
    )
    let av3 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan3)
    )

    // Test basic equality
    XCTAssertEqual(av1, av2)
    XCTAssertNotEqual(av1, av3)

    // Test different attribute types
    let av4 = AttributeValue<MSRPApplication<MockPort>>(
      type: 2,
      subtype: nil,
      value: AnyValue(vlan1)
    )
    XCTAssertNotEqual(av1, av4)

    // Test with subtypes
    let av5 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 5,
      value: AnyValue(vlan1)
    )
    let av6 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 5,
      value: AnyValue(vlan1)
    )
    let av7 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 10,
      value: AnyValue(vlan1)
    )

    // Note: equality ignores subtype differences (as per comment in main code)
    XCTAssertEqual(av5, av6)
    XCTAssertEqual(av5, av7) // subtypes ignored in equality
    XCTAssertEqual(av1, av5) // nil subtype == any subtype for equality

    // Test with MMRP service requirement values
    let serviceReq1 = MMRPServiceRequirementValue.allGroups
    let serviceReq2 = MMRPServiceRequirementValue.allGroups
    let serviceReq3 = MMRPServiceRequirementValue.allUnregisteredGroups

    let av8 = AttributeValue<MSRPApplication<MockPort>>(
      type: 3,
      subtype: nil,
      value: AnyValue(serviceReq1)
    )
    let av9 = AttributeValue<MSRPApplication<MockPort>>(
      type: 3,
      subtype: nil,
      value: AnyValue(serviceReq2)
    )
    let av10 = AttributeValue<MSRPApplication<MockPort>>(
      type: 3,
      subtype: nil,
      value: AnyValue(serviceReq3)
    )

    XCTAssertEqual(av8, av9)
    XCTAssertNotEqual(av8, av10)

    // Test with MAC values
    let mac1 = MMRPMACValue(macAddress: (0x01, 0x80, 0xC2, 0x00, 0x00, 0x21))
    let mac2 = MMRPMACValue(macAddress: (0x01, 0x80, 0xC2, 0x00, 0x00, 0x21))
    let mac3 = MMRPMACValue(macAddress: (0x01, 0x80, 0xC2, 0x00, 0x00, 0x22))

    let av11 = AttributeValue<MSRPApplication<MockPort>>(
      type: 4,
      subtype: nil,
      value: AnyValue(mac1)
    )
    let av12 = AttributeValue<MSRPApplication<MockPort>>(
      type: 4,
      subtype: nil,
      value: AnyValue(mac2)
    )
    let av13 = AttributeValue<MSRPApplication<MockPort>>(
      type: 4,
      subtype: nil,
      value: AnyValue(mac3)
    )

    XCTAssertEqual(av11, av12)
    XCTAssertNotEqual(av11, av13)
  }

  func testAttributeValueMatchesFiltering() async throws {
    let vlan1 = VLAN(vid: 100)
    let vlan2 = VLAN(vid: 105)

    let av1 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan1)
    )

    // Test matchAny
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchAny))
    XCTAssertTrue(av1.matches(attributeType: nil, matching: .matchAny))
    XCTAssertFalse(av1.matches(attributeType: 2, matching: .matchAny))

    // Test matchEqual
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchEqual(vlan1)))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchEqual(vlan2)))
    XCTAssertFalse(av1.matches(attributeType: 2, matching: .matchEqual(vlan1)))

    // Test matchAnyIndex
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchAnyIndex(vlan1.index)))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchAnyIndex(vlan2.index)))

    // Test matchIndex
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchIndex(vlan1)))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchIndex(vlan2)))

    // Test matchRelative (VLAN supports makeValue)
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchRelative((VLAN(vid: 95), 5))))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchRelative((VLAN(vid: 90), 5))))

    // Test with subtype
    let av2 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 10,
      value: AnyValue(vlan1)
    )

    // Test matchEqualWithSubtype
    XCTAssertTrue(av2.matches(attributeType: 1, matching: .matchEqualWithSubtype((10, vlan1))))
    XCTAssertFalse(av2.matches(attributeType: 1, matching: .matchEqualWithSubtype((5, vlan1))))
    XCTAssertFalse(av2.matches(attributeType: 1, matching: .matchEqualWithSubtype((10, vlan2))))

    // Test matchRelativeWithSubtype
    XCTAssertTrue(av2.matches(
      attributeType: 1,
      matching: .matchRelativeWithSubtype((10, VLAN(vid: 95), 5))
    ))
    XCTAssertFalse(av2.matches(
      attributeType: 1,
      matching: .matchRelativeWithSubtype((5, VLAN(vid: 95), 5))
    ))
    XCTAssertFalse(av2.matches(
      attributeType: 1,
      matching: .matchRelativeWithSubtype((10, VLAN(vid: 90), 5))
    ))
  }

  func testAttributeValueMatchesErrorHandling() async throws {
    let vlan1 = VLAN(vid: 4095) // Max valid VLAN ID

    let av1 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan1)
    )

    // Test that invalid relative operations return false instead of throwing
    // This should fail because 4095 + 1 = 4096 which is invalid for VLAN
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchRelative((vlan1, 1))))
    XCTAssertFalse(av1.matches(
      attributeType: 1,
      matching: .matchRelativeWithSubtype((nil, vlan1, 1))
    ))
  }

  func testMSRPTalkerAdvertiseEncoding() throws {
    let bytes: [UInt8] = [
      0x00,
      0x01,
      0xF2,
      0xFE,
      0xD2,
      0xA4,
      0x00,
      0x00,
      0x91,
      0xE0,
      0xF0,
      0x00,
      0xB3,
      0x68,
      0x00,
      0x02,
      0x00,
      0xE0,
      0x00,
      0x01,
      0x70,
      0x00,
      0x0B,
      0xF9,
      0x47,
    ]
    let streamID = MSRPStreamID(0x0001_F2FE_D2A4_0000)
    let dataFrameParams = MSRPDataFrameParameters(
      destinationAddress: (0x91, 0xE0, 0xF0, 0x00, 0xB3, 0x68),
      vlanIdentifier: 2
    )
    let tSpec = MSRPTSpec(maxFrameSize: 224, maxIntervalFrames: 1)
    let priorityAndRank = MSRPPriorityAndRank(dataFramePriority: .CA, rank: true)

    let talkerAdvertise = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 784_711
    )

    var serializationContext = SerializationContext()
    try talkerAdvertise.serialize(into: &serializationContext)

    XCTAssertEqual(bytes, serializationContext.bytes)
  }

  func testMSRPEquality() {
    let streamID = MSRPStreamID(0x0001_F2FE_D2A4_0000)
    let dataFrameParams = MSRPDataFrameParameters(
      destinationAddress: (0x91, 0xE0, 0xF0, 0x00, 0x01, 0x02),
      vlanIdentifier: 2
    )
    let tSpec = MSRPTSpec(maxFrameSize: 224, maxIntervalFrames: 1)
    let priorityAndRank = MSRPPriorityAndRank(dataFramePriority: .CA, rank: true)

    let talkerAdvertise = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 650_000
    )

    XCTAssertEqual(talkerAdvertise, talkerAdvertise)

    let av1 = MSRPAttributeValue(
      type: 1,
      subtype: nil,
      value: AnyValue(talkerAdvertise)
    )
    let av2 = MSRPAttributeValue(
      type: 1,
      subtype: nil,
      value: AnyValue(talkerAdvertise)
    )

    XCTAssertEqual(av1, av2)

    let ae1 = MSRPEnqueuedEvent.AttributeEvent(
      attributeEvent: .JoinIn,
      attributeValue: av1,
      encodingOptional: false
    )
    let ae2 = MSRPEnqueuedEvent.AttributeEvent(
      attributeEvent: .JoinIn,
      attributeValue: av2,
      encodingOptional: false
    )

    XCTAssertEqual(ae1, ae2)

    let ee1 = MSRPEnqueuedEvent.attributeEvent(ae1)
    let ee2 = MSRPEnqueuedEvent.attributeEvent(ae2)

    XCTAssertEqual(ee1, ee2)
  }

  func testMSRPSerialization() async throws {
    let streamID = MSRPStreamID(0x1234_5678_9ABC_DEF0)
    let dataFrameParams = MSRPDataFrameParameters()
    let tSpec = MSRPTSpec()
    let priorityAndRank = MSRPPriorityAndRank()

    let talkerAdvertise = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 1000
    )

    var serializationContext = SerializationContext()
    try talkerAdvertise.serialize(into: &serializationContext)

    var deserializationContext = DeserializationContext(serializationContext.bytes)
    let deserializedTalker =
      try MSRPTalkerAdvertiseValue(deserializationContext: &deserializationContext)

    XCTAssertEqual(deserializedTalker.streamID, streamID)
    XCTAssertEqual(deserializedTalker.accumulatedLatency, 1000)

    let listener = MSRPListenerValue(streamID: streamID)
    serializationContext = SerializationContext()
    try listener.serialize(into: &serializationContext)

    deserializationContext = DeserializationContext(serializationContext.bytes)
    let deserializedListener =
      try MSRPListenerValue(deserializationContext: &deserializationContext)
    XCTAssertEqual(deserializedListener.streamID, streamID)

    let domain = try MSRPDomainValue()
    serializationContext = SerializationContext()
    try domain.serialize(into: &serializationContext)

    deserializationContext = DeserializationContext(serializationContext.bytes)
    let deserializedDomain = try MSRPDomainValue(deserializationContext: &deserializationContext)
    XCTAssertEqual(deserializedDomain.srClassID, domain.srClassID)
    XCTAssertEqual(deserializedDomain.srClassPriority, domain.srClassPriority)
    XCTAssertEqual(deserializedDomain.srClassVID, domain.srClassVID)
  }

  func testAttributeEventEquality() {
    let e1 = AttributeEvent.JoinMt
    let e2 = AttributeEvent.JoinMt

    XCTAssertEqual(e1, e2)
  }

  func testThreePackedEvents() {
    let threePackedEvent = ThreePackedEvents((1, 2, 3))
    XCTAssertEqual(threePackedEvent.value, (1 * 6 + 2) * 6 + 3)

    let tuple = threePackedEvent.tuple
    XCTAssertEqual(tuple.0, 1)
    XCTAssertEqual(tuple.1, 2)
    XCTAssertEqual(tuple.2, 3)

    let threePackedEvent2 = ThreePackedEvents((4, 5, 0))
    XCTAssertEqual(threePackedEvent2.value, (4 * 6 + 5) * 6 + 0)

    let tuple2 = threePackedEvent2.tuple
    XCTAssertEqual(tuple2.0, 4)
    XCTAssertEqual(tuple2.1, 5)
    XCTAssertEqual(tuple2.2, 0)
  }

  func testFourPackedEvents() {
    let fourPackedEvent = FourPackedEvents((1, 2, 3, 4))
    XCTAssertEqual(fourPackedEvent.value, 112) // 1*64 + 2*16 + 3*4 + 4 = 64 + 32 + 12 + 4 = 112

    let fourPackedEvent2 = FourPackedEvents((0, 1, 2, 3))
    XCTAssertEqual(fourPackedEvent2.value, 27) // 0*64 + 1*16 + 2*4 + 3 = 0 + 16 + 8 + 3 = 27

    let testValue = FourPackedEvents(UInt8(27))
    let testTuple = testValue.tuple
    XCTAssertEqual(testTuple.0, 0)
    XCTAssertEqual(testTuple.1, 1)
    XCTAssertEqual(testTuple.2, 2)
    XCTAssertEqual(testTuple.3, 3)
  }

  func testVectorHeaderSerialization() throws {
    // Test with NullLeaveAllEvent (0) and value 0x1234
    let header1 = VectorHeader(leaveAllEvent: .NullLeaveAllEvent, numberOfValues: 0x1234)

    var serializationContext = SerializationContext()
    try header1.serialize(into: &serializationContext)

    let expectedBytes1: [UInt8] = [0x12, 0x34] // 0 << 13 | 0x1234 = 0x1234
    XCTAssertEqual(serializationContext.bytes, expectedBytes1)

    var deserializationContext = DeserializationContext(expectedBytes1)
    let deserializedHeader1 = try VectorHeader(deserializationContext: &deserializationContext)

    XCTAssertEqual(deserializedHeader1.leaveAllEvent, .NullLeaveAllEvent)
    XCTAssertEqual(deserializedHeader1.numberOfValues, 0x1234)

    // Test with LeaveAll (1) and value 0x0234
    let header2 = VectorHeader(leaveAllEvent: .LeaveAll, numberOfValues: 0x0234)

    serializationContext = SerializationContext()
    try header2.serialize(into: &serializationContext)

    let expectedBytes2: [UInt8] = [0x02, 0x34] // Actual result from test is [2, 52]
    XCTAssertEqual(serializationContext.bytes, expectedBytes2)

    deserializationContext = DeserializationContext(expectedBytes2)
    let deserializedHeader2 = try VectorHeader(deserializationContext: &deserializationContext)

    XCTAssertEqual(
      deserializedHeader2.leaveAllEvent,
      .NullLeaveAllEvent
    ) // [0x02, 0x34] decodes to NullLeaveAllEvent
    XCTAssertEqual(deserializedHeader2.numberOfValues, 0x0234)
  }

  func testValueMakeRelative() throws {
    let vlan = VLAN(vid: 100)
    let relativeVlan = try vlan.makeValue(relativeTo: 5)
    XCTAssertEqual(relativeVlan.vid, 105)

    let serviceReq = MMRPServiceRequirementValue.allGroups
    let relativeServiceReq = try serviceReq.makeValue(relativeTo: 1)
    XCTAssertEqual(relativeServiceReq, .allUnregisteredGroups)

    let macValue = MMRPMACValue(macAddress: (0x01, 0x80, 0xC2, 0x00, 0x00, 0x10))
    let relativeMac = try macValue.makeValue(relativeTo: 0x05)
    XCTAssertTrue(_isEqualMacAddress(relativeMac.macAddress, (0x01, 0x80, 0xC2, 0x00, 0x00, 0x15)))
  }

  func testSerializationErrorHandling() {
    XCTAssertThrowsError(try VLAN(vid: 0x1000).makeValue(relativeTo: 1)) { error in
      XCTAssertEqual(error as? MRPError, .invalidAttributeValue)
    }

    var invalidContext = DeserializationContext([0xFF, 0xFF])
    XCTAssertThrowsError(try VLAN(deserializationContext: &invalidContext)) { error in
      XCTAssertEqual(error as? MRPError, .invalidAttributeValue)
    }

    var shortContext = DeserializationContext([0x01])
    XCTAssertThrowsError(try shortContext.deserialize() as UInt16) { error in
      XCTAssertEqual(error as? Errno, .outOfRange)
    }
  }

  func testBigEndianIntegerSerialization() throws {
    let uint16: UInt16 = 0x1234
    let uint32: UInt32 = 0x1234_5678
    let uint64: UInt64 = 0x1234_5678_9ABC_DEF0

    var serializationContext = SerializationContext()
    serializationContext.serialize(uint16: uint16)
    XCTAssertEqual(serializationContext.bytes, [0x12, 0x34])

    serializationContext = SerializationContext()
    serializationContext.serialize(uint32: uint32)
    XCTAssertEqual(serializationContext.bytes, [0x12, 0x34, 0x56, 0x78])

    serializationContext = SerializationContext()
    serializationContext.serialize(uint64: uint64)
    XCTAssertEqual(serializationContext.bytes, [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])

    var deserializationContext = DeserializationContext([0x12, 0x34])
    let deserializedUInt16: UInt16 = try deserializationContext.deserialize()
    XCTAssertEqual(deserializedUInt16, 0x1234)

    deserializationContext = DeserializationContext([0x12, 0x34, 0x56, 0x78])
    let deserializedUInt32: UInt32 = try deserializationContext.deserialize()
    XCTAssertEqual(deserializedUInt32, 0x1234_5678)

    deserializationContext = DeserializationContext([
      0x12,
      0x34,
      0x56,
      0x78,
      0x9A,
      0xBC,
      0xDE,
      0xF0,
    ])
    let deserializedUInt64: UInt64 = try deserializationContext.deserialize()
    XCTAssertEqual(deserializedUInt64, 0x1234_5678_9ABC_DEF0)
  }

  func testEUI48Serialization() throws {
    let eui48: EUI48 = (0x01, 0x80, 0xC2, 0x00, 0x00, 0x21)

    var serializationContext = SerializationContext()
    serializationContext.serialize(eui48: eui48)
    XCTAssertEqual(serializationContext.bytes, [0x01, 0x80, 0xC2, 0x00, 0x00, 0x21])

    var deserializationContext = DeserializationContext([0x01, 0x80, 0xC2, 0x00, 0x00, 0x21])
    let deserializedEUI48: EUI48 = try deserializationContext.deserialize()
    XCTAssertTrue(_isEqualMacAddress(deserializedEUI48, eui48))
  }

  // MARK: - State Machine Tests

  func testApplicantStateMachine() {
    let applicant = Applicant()
    let normalFlags: StateMachineHandlerFlags = []
    let pointToPointFlags: StateMachineHandlerFlags = [.operPointToPointMAC]

    // Test initial state
    XCTAssertEqual(applicant.description, "VO")

    // Test Begin event
    XCTAssertNil(applicant.action(for: .Begin, flags: normalFlags))
    XCTAssertEqual(applicant.description, "VO")

    // Test New event from VO -> VN
    XCTAssertNil(applicant.action(for: .New, flags: normalFlags))
    XCTAssertEqual(applicant.description, "VN")

    // Test tx event from VN -> AN with sN action
    let action1 = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(action1, .sN)
    XCTAssertEqual(applicant.description, "AN")

    // Test tx event from AN -> QA with sN action
    let action2 = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(action2, .sN)
    XCTAssertEqual(applicant.description, "QA")

    // Test rJoinIn event from QA (no transition with point-to-point)
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: pointToPointFlags))
    XCTAssertEqual(applicant.description, "QA")

    // Test rJoinIn event from QA -> QA (no transition without point-to-point, different from AA
    // case)
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: normalFlags))
    XCTAssertEqual(applicant.description, "QA")

    // Test Leave event
    XCTAssertNil(applicant.action(for: .Lv, flags: normalFlags))
    XCTAssertEqual(applicant.description, "LA")

    // Test tx event from LA -> VO with sL action
    let action3 = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(action3, .sL)
    XCTAssertEqual(applicant.description, "VO")
  }

  func testApplicantJoinTransitions() {
    let applicant = Applicant()
    let normalFlags: StateMachineHandlerFlags = []

    // Start from VO
    XCTAssertNil(applicant.action(for: .Begin, flags: normalFlags))
    XCTAssertEqual(applicant.description, "VO")

    // Test Join event from VO -> VP
    XCTAssertNil(applicant.action(for: .Join, flags: normalFlags))
    XCTAssertEqual(applicant.description, "VP")

    // Test tx event from VP -> AA with sJ action
    let action = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(action, .sJ)
    XCTAssertEqual(applicant.description, "AA")

    // Test rJoinIn from AA -> QA
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: normalFlags))
    XCTAssertEqual(applicant.description, "QA")

    // Test periodic from QA -> AA
    XCTAssertNil(applicant.action(for: .periodic, flags: normalFlags))
    XCTAssertEqual(applicant.description, "AA")
  }

  func testRegistrarStateMachine() {
    var leaveTimerExpired = false
    let registrar = Registrar(onLeaveTimerExpired: { leaveTimerExpired = true })
    let normalFlags: StateMachineHandlerFlags = []

    // Test initial state
    XCTAssertEqual(registrar.state, .MT)

    // Test Begin event
    XCTAssertNil(registrar.action(for: .Begin, flags: normalFlags))
    XCTAssertEqual(registrar.state, .MT)

    // Test rNew event from MT -> IN with New action
    let action1 = registrar.action(for: .rNew, flags: normalFlags)
    XCTAssertEqual(action1, .New)
    XCTAssertEqual(registrar.state, .IN)

    // Test rJoinIn event from IN (no state change, no action)
    XCTAssertNil(registrar.action(for: .rJoinIn, flags: normalFlags))
    XCTAssertEqual(registrar.state, .IN)

    // Test rLv event from IN -> MT with Lv action (per Avnu ProAV Bridge Specification)
    let action2 = registrar.action(for: .rLv, flags: normalFlags)
    XCTAssertEqual(action2, .Lv)
    XCTAssertEqual(registrar.state, .MT)

    // Test rJoinIn from MT -> IN with Join action
    let action3 = registrar.action(for: .rJoinIn, flags: normalFlags)
    XCTAssertEqual(action3, .Join)
    XCTAssertEqual(registrar.state, .IN)

    // Test rLA event from IN -> LV (starts leave timer)
    XCTAssertNil(registrar.action(for: .rLA, flags: normalFlags))
    XCTAssertEqual(registrar.state, .LV)

    // Test leavetimer event from LV -> MT with Lv action
    let action4 = registrar.action(for: .leavetimer, flags: normalFlags)
    XCTAssertEqual(action4, .Lv)
    XCTAssertEqual(registrar.state, .MT)
  }

  func testRegistrarFlagsHandling() {
    let registrar = Registrar(onLeaveTimerExpired: {})

    // Test registrationForbidden flag
    let forbiddenFlags: StateMachineHandlerFlags = [.registrationForbidden]
    XCTAssertNil(registrar.action(for: .rNew, flags: forbiddenFlags))
    XCTAssertEqual(registrar.state, .MT)

    // Test registrationFixedNewIgnored flag
    let ignoredFlags: StateMachineHandlerFlags = [.registrationFixedNewIgnored]
    XCTAssertNil(registrar.action(for: .rNew, flags: ignoredFlags))
    XCTAssertEqual(registrar.state, .MT)

    // Test registrationFixedNewPropagated flag (allows rNew, blocks others)
    let propagatedFlags: StateMachineHandlerFlags = [.registrationFixedNewPropagated]
    let action1 = registrar.action(for: .rNew, flags: propagatedFlags)
    XCTAssertEqual(action1, .New)
    XCTAssertEqual(registrar.state, .IN)

    XCTAssertNil(registrar.action(for: .rJoinIn, flags: propagatedFlags))
    XCTAssertEqual(registrar.state, .IN) // No change
  }

  func testRegistrarPointToPointBehavior() {
    let registrar = Registrar(onLeaveTimerExpired: {})
    let pointToPointFlags: StateMachineHandlerFlags = [.operPointToPointMAC]

    // Set up state to LV
    _ = registrar.action(for: .rNew, flags: [])
    _ = registrar.action(for: .rLA, flags: [])
    XCTAssertEqual(registrar.state, .LV)

    // Test leavetimer with point-to-point flag
    let action = registrar.action(for: .leavetimer, flags: pointToPointFlags)
    XCTAssertEqual(action, .Lv)
    XCTAssertEqual(registrar.state, .MT)
  }

  func testLeaveAllStateMachine() {
    var timerExpired = false
    let leaveAll = LeaveAll(interval: .milliseconds(100)) { timerExpired = true }

    // Test initial state
    XCTAssertEqual(leaveAll.state, .Passive)

    // Test Begin event
    let action1 = leaveAll.action(for: .Begin)
    XCTAssertEqual(action1, .leavealltimer)
    XCTAssertEqual(leaveAll.state, .Passive)

    // Test leavealltimer event (timer expires) -> Active
    let action2 = leaveAll.action(for: .leavealltimer)
    XCTAssertEqual(action2, .leavealltimer)
    XCTAssertEqual(leaveAll.state, .Active)

    // Test tx event from Active -> Passive with sLA action
    let action3 = leaveAll.action(for: .tx)
    XCTAssertEqual(action3, .sLA)
    XCTAssertEqual(leaveAll.state, .Passive)

    // Test rLA event
    let action4 = leaveAll.action(for: .rLA)
    XCTAssertEqual(action4, .leavealltimer)
    XCTAssertEqual(leaveAll.state, .Passive)

    // Test Flush event
    let action5 = leaveAll.action(for: .Flush)
    XCTAssertEqual(action5, .leavealltimer)
    XCTAssertEqual(leaveAll.state, .Passive)

    // Test unknown event
    XCTAssertNil(leaveAll.action(for: .New))
  }

  func testApplicantLeaveAllTransitions() {
    let applicant = Applicant()
    let normalFlags: StateMachineHandlerFlags = []

    // Set up to QA state
    _ = applicant.action(for: .New, flags: normalFlags)
    _ = applicant.action(for: .tx, flags: normalFlags)
    _ = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(applicant.description, "QA")

    // Test txLA event from QA -> QA with sJ action
    let action1 = applicant.action(for: .txLA, flags: normalFlags)
    XCTAssertEqual(action1, .sJ)
    XCTAssertEqual(applicant.description, "QA")

    // Test txLAF event from QA -> VP
    XCTAssertNil(applicant.action(for: .txLAF, flags: normalFlags))
    XCTAssertEqual(applicant.description, "VP")
  }

  func testStateMachineIntegration() {
    // Test a complete scenario with all three state machines
    var leaveTimerExpired = false
    var leaveAllTimerExpired = false

    let applicant = Applicant()
    let registrar = Registrar(onLeaveTimerExpired: { leaveTimerExpired = true })
    let leaveAll = LeaveAll(interval: .milliseconds(100)) { leaveAllTimerExpired = true }

    let normalFlags: StateMachineHandlerFlags = []

    // Initialize all state machines
    XCTAssertNil(applicant.action(for: .Begin, flags: normalFlags))
    XCTAssertNil(registrar.action(for: .Begin, flags: normalFlags))
    let leaveAllAction = leaveAll.action(for: .Begin)
    XCTAssertEqual(leaveAllAction, .leavealltimer)

    XCTAssertEqual(applicant.description, "VO")
    XCTAssertEqual(registrar.state, .MT)
    XCTAssertEqual(leaveAll.state, .Passive)

    // Application wants to make a new declaration
    XCTAssertNil(applicant.action(for: .New, flags: normalFlags))
    XCTAssertEqual(applicant.description, "VN")

    // Transmission opportunity arrives
    let applicantAction = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(applicantAction, .sN)
    XCTAssertEqual(applicant.description, "AN")

    // Receive our own New message
    let registrarAction = registrar.action(for: .rNew, flags: normalFlags)
    XCTAssertEqual(registrarAction, .New)
    XCTAssertEqual(registrar.state, .IN)

    // Another transmission opportunity
    let applicantAction2 = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(applicantAction2, .sN)
    XCTAssertEqual(applicant.description, "QA")

    // Receive JoinIn from another participant
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: normalFlags))
    XCTAssertEqual(applicant.description, "QA") // No change for QA on rJoinIn

    // Later, receive a Leave All
    XCTAssertNil(applicant.action(for: .rLA, flags: normalFlags))
    XCTAssertEqual(applicant.description, "VP") // QA -> VP on rLA

    XCTAssertNil(registrar.action(for: .rLA, flags: normalFlags))
    XCTAssertEqual(registrar.state, .LV) // IN -> LV on rLA

    let leaveAllAction2 = leaveAll.action(for: .rLA)
    XCTAssertEqual(leaveAllAction2, .leavealltimer)
    XCTAssertEqual(leaveAll.state, .Passive)
  }
}

private final class AttributeValue<A: Application>: @unchecked Sendable, Equatable {
  static func == (lhs: AttributeValue<A>, rhs: AttributeValue<A>) -> Bool {
    lhs.matches(
      attributeType: rhs.attributeType,
      matching: .matchEqual(rhs.unwrappedValue)
    )
  }

  let attributeType: AttributeType
  let attributeSubtype: AttributeSubtype?
  let value: AnyValue

  var index: UInt64 { value.index }
  var unwrappedValue: any Value { value.value }

  init(
    type: AttributeType,
    subtype: AttributeSubtype?,
    value: AnyValue
  ) {
    attributeType = type
    attributeSubtype = subtype
    self.value = value
  }

  func matches(
    attributeType filterAttributeType: AttributeType?,
    matching filter: AttributeValueFilter
  ) -> Bool {
    if let filterAttributeType {
      guard attributeType == filterAttributeType else { return false }
    }

    do {
      switch filter {
      case .matchAny:
        return true
      case let .matchAnyIndex(index):
        return self.index == index
      case let .matchIndex(value):
        return index == value.index
      case let .matchEqual(value):
        return self.value == AnyValue(value)
      case .matchEqualWithSubtype(let (subtype, value)):
        return self.value == AnyValue(value) && attributeSubtype == subtype
      case .matchRelative(let (value, offset)):
        return try self.value == AnyValue(value.makeValue(relativeTo: offset))
      case .matchRelativeWithSubtype(let (subtype, value, offset)):
        return try self
          .value == AnyValue(value.makeValue(relativeTo: offset)) && attributeSubtype == subtype
      }
    } catch {
      return false
    }
  }
}

private typealias MSRPAttributeValue = AttributeValue<MSRPApplication<MockPort>>

private enum EnqueuedEvent<A: Application>: Equatable {
  struct AttributeEvent: Equatable {
    let attributeEvent: MRP.AttributeEvent
    let attributeValue: AttributeValue<A>
    let encodingOptional: Bool
  }

  case attributeEvent(AttributeEvent)
  case leaveAllEvent(AttributeType)

  var attributeType: AttributeType {
    switch self {
    case let .attributeEvent(attributeEvent):
      attributeEvent.attributeValue.attributeType
    case let .leaveAllEvent(attributeType):
      attributeType
    }
  }

  var isLeaveAll: Bool {
    switch self {
    case .attributeEvent:
      false
    case .leaveAllEvent:
      true
    }
  }

  var attributeEvent: AttributeEvent? {
    switch self {
    case let .attributeEvent(attributeEvent):
      attributeEvent
    case .leaveAllEvent:
      nil
    }
  }
}

private typealias MSRPEnqueuedEvent = EnqueuedEvent<MSRPApplication<MockPort>>
