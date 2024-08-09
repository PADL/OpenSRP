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
import Logging

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

  var macAddress: MRP.EUI48 { (0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF) }

  init(id: ID) {
    self.id = id
  }
}

struct MockBridge: MRP.Bridge, CustomStringConvertible {
  var notifications = AsyncEmptySequence<MRP.PortNotification<MockPort>>().eraseToAnyAsyncSequence()
  var rxPackets = AsyncEmptySequence<(Int, MRP.IEEE802Packet)>().eraseToAnyAsyncSequence()

  func getPorts() async throws -> Set<MockPort> {
    [MockPort(id: 0)]
  }

  typealias P = MockPort

  var description: String { "MockBridge" }
  var vlans: Set<MRP.VLAN> { [] }

  func register(groupAddress: MRP.EUI48, etherType: UInt16) throws {}

  func deregister(groupAddress: MRP.EUI48, etherType: UInt16) throws {}

  func willRun(ports: Set<MockPort>) throws {}

  func willShutdown() throws {}

  func tx(_ packet: MRP.IEEE802Packet, on: Int) async throws {}
}

final class MRPTests: XCTestCase {
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
        XCTAssertEqual(firstAttribute.vector, [114])
        XCTAssertEqual(firstAttribute.threePackedEvents, [3, 1, 0])
      }
    }
  }
}
