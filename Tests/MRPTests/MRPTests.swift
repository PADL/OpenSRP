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

@testable import MRP
import XCTest
@preconcurrency
import AsyncExtensions
import IEEE802
import Logging
import SystemPackage

struct MockPort: MRP.Port, Equatable, Hashable, Identifiable, Sendable, CustomStringConvertible {
  var id: Int

  static func == (_ lhs: MockPort, _ rhs: MockPort) -> Bool {
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
        XCTAssertEqual(try firstAttribute.attributeEvents, [.JoinMt, .JoinIn, .New])

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
}
