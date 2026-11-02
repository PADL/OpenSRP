//
// Copyright (c) 2026 PADL Software Pty Ltd
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

import BinaryParsing
import IEEE802
@testable import PMC
import XCTest

private func _hex(_ string: String) -> [UInt8] {
  var bytes = [UInt8]()
  var index = string.startIndex
  while index < string.endIndex {
    let next = string.index(index, offsetBy: 2)
    bytes.append(UInt8(string[index..<next], radix: 16)!)
    index = next
  }
  return bytes
}

private func _be(_ value: some FixedWidthInteger) -> [UInt8] {
  withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

// A notification as ptp4l sends it: port_management_notify() builds a RESPONSE with both
// boundary hops 1 from the notifying port (clock.c clock_notify_event(), port.c
// port_notify_event()); clock_send_notification() fills in the subscriber's sequence ID and
// identity. The header carries linuxptp's default version byte 0x12 (msg.h PTP_VERSION).
private func _notification(
  from source: PTP.PortIdentity,
  sequenceId: UInt16 = 7,
  managementId: UInt16,
  data: [UInt8]
) throws -> [UInt8] {
  // clock.c pads the data to an even length and counts the pad in the TLV length
  let data = data.count % 2 == 0 ? data : data + [0]
  let tlv = _be(UInt16(0x0001)) + _be(UInt16(2 + data.count)) + _be(managementId) + data
  var serializationContext = SerializationContext()
  try source.serialize(into: &serializationContext)
  let messageLength = UInt16(48 + tlv.count)
  var bytes: [UInt8] = [0x1D, 0x12] + _be(messageLength) + [0, 0, 0, 0]
  bytes += [UInt8](repeating: 0, count: 12) // correctionField, messageTypeSpecific
  bytes += serializationContext.bytes + _be(sequenceId) + [0x04, 0x7F]
  bytes += [UInt8](repeating: 0xEE, count: 10) // targetPortIdentity: the subscriber's
  bytes += [0x01, 0x01, 0x02, 0x00] // boundary hops, RESPONSE, reserved
  return bytes + tlv
}

private let _clock = PTP.ClockIdentity(id: (0x00, 0x1B, 0x21, 0xFF, 0xFE, 0xAA, 0xBB, 0xCC))

final class PMCEventTests: XCTestCase {
  // MARK: - SUBSCRIBE_EVENTS_NP encoding

  func testSubscribeEventsBitmaskMatchesLinuxptp() throws {
    // notification.h: enum notification { PORT_STATE, TIME_SYNC, PARENT_DATA_SET, CMLDS },
    // event_bitmask_set() sets bit (event % 8) of byte (event / 8)
    let subscription = SubscribeEventsNP(duration: 30, events: [.portState, .cmlds])
    let bytes = try subscription.serialized()
    XCTAssertEqual(bytes.count, 2 + SubscribeEventsNP.EventBitmaskCount) // tlv.h: 66
    XCTAssertEqual(Array(bytes[0..<2]), [0x00, 0x1E]) // duration, network order (tlv.c)
    XCTAssertEqual(bytes[2], 0x09)
    XCTAssertTrue(bytes[3...].allSatisfy { $0 == 0 })

    let all = SubscribeEventsNP(duration: 1, events: Set(SubscribeEventsNP.Event.allCases))
    XCTAssertEqual(try all.serialized()[2], 0x0F)
    XCTAssertEqual(Set(all.events), Set(SubscribeEventsNP.Event.allCases))
  }

  func testSubscribeEventsSetMatchesLinuxptpPmc() throws {
    // captured from linuxptp's pmc (v4.4-87): pmc -u -b 0 "SET SUBSCRIBE_EVENTS_NP duration
    // 30 NOTIFY_PORT_STATE on NOTIFY_TIME_SYNC off NOTIFY_PARENT_DATA_SET off NOTIFY_CMLDS on"
    let captured = _hex(
      "0d12007800000000000000000000000000000000000000000000001fb1be0000007f" +
        "ffffffffffffffffffff00000100" +
        "00010044c003001e09" + String(repeating: "00", count: 63)
    )
    XCTAssertEqual(captured.count, 120)

    // pmc -u sends transportSpecific 0 unless given -t
    let request = try PTPManagementClient._makeRequest(
      transportSpecific: 0,
      domainNumber: 0,
      sourcePortIdentity: PTP.PortIdentity(
        clockIdentity: PTP.ClockIdentity(id: (0, 0, 0, 0, 0, 0, 0, 0x1F)),
        portNumber: 0xB1BE
      ),
      targetPortIdentity: PTP.PortIdentity(),
      sequenceId: 0,
      action: .set,
      managementTLV: PTPManagementTLV(SubscribeEventsNP(
        duration: 30,
        events: [.portState, .cmlds]
      ))
    )
    let bytes = try request.serialized()
    XCTAssertEqual(bytes.count, captured.count)
    // the management body (target, hops, action, TLV) and every header field ptp4l
    // reads from a management request are identical
    XCTAssertEqual(Array(bytes[34...]), Array(captured[34...]))
    XCTAssertEqual(Array(bytes[2..<4]), Array(captured[2..<4])) // messageLength
    XCTAssertEqual(Array(bytes[20..<32]), Array(captured[20..<32])) // source, sequenceId
    XCTAssertEqual(bytes[0], captured[0]) // transportSpecific, messageType
    // header fields this client has always sent differently, which ptp4l ignores here:
    // minor version, flags, controlField, logMessageInterval
    let differing = Set((0..<34).filter { bytes[$0] != captured[$0] })
    XCTAssertTrue(differing.isSubset(of: [1, 6, 7, 32, 33]), "\(differing.sorted())")
  }

  func testSubscriptionHoldsOnlyMatchingUnexpiredReply() throws {
    let ours = SubscribeEventsNP(duration: 30, events: [.portState, .cmlds])
    func reply(_ duration: UInt16, _ mask: UInt8) throws -> SubscribeEventsNP {
      let bytes = _be(duration) + [mask] + [UInt8](repeating: 0, count: 63)
      return try bytes.withParserSpan { try SubscribeEventsNP(parsing: &$0) }
    }
    XCTAssertTrue(try reply(17, 0x09).holds(ours))
    // clock_get_subscription(): an unknown client reads back a zero mask and duration
    XCTAssertFalse(try reply(0, 0x00).holds(ours))
    XCTAssertFalse(try reply(0, 0x09).holds(ours)) // expired, not yet pruned
    XCTAssertFalse(try reply(17, 0x01).holds(ours))
  }

  // MARK: - notification decoding

  func testPortStateNotificationDecodes() throws {
    let port = PTP.PortIdentity(clockIdentity: _clock, portNumber: 2)
    var serializationContext = SerializationContext()
    try port.serialize(into: &serializationContext)
    // struct portDS: portIdentity, portState SLAVE, logMinDelayReqInterval, peerMeanPathDelay
    // (612.5 ns as TimeInterval), logAnnounceInterval, announceReceiptTimeout,
    // logSyncInterval, delayMechanism P2P, logMinPdelayReqInterval, versionNumber
    let data = serializationContext.bytes + [9, 0] + _be(Int64(612 << 16 | 0x8000)) +
      [0, 3, 0xFD, 2, 0, 2]
    let pdu = try _notification(from: port, managementId: 0x2004, data: data)
    guard case let .portState(portDataSet) = try PTPManagementEvent(notification: pdu) else {
      return XCTFail("expected a port state event")
    }
    XCTAssertEqual(portDataSet.portIdentity, port)
    XCTAssertEqual(portDataSet.portState, .slave)
    XCTAssertEqual(portDataSet.meanLinkDelay, 612 << 16 | 0x8000)
    XCTAssertEqual(portDataSet.delayMechanism, .p2p)
    XCTAssertEqual(portDataSet.logSyncInterval, -3)
  }

  func testCmldsNotificationNamesTheSendingPort() throws {
    // struct cmlds_info_np: meanLinkDelay, scaledNeighborRateRatio, as_capable
    let port = PTP.PortIdentity(clockIdentity: _clock, portNumber: 3)
    let data = _be(Int64(1200 << 16)) + _be(Int32(-42)) + _be(UInt32(1))
    let pdu = try _notification(from: port, managementId: 0xC00B, data: data)
    guard case let .cmlds(source, info) = try PTPManagementEvent(notification: pdu) else {
      return XCTFail("expected a CMLDS event")
    }
    XCTAssertEqual(source, port)
    XCTAssertEqual(info.meanLinkDelay, 1200 << 16)
    XCTAssertEqual(info.scaledNeighborRateRatio, -42)
    XCTAssertEqual(info.asCapable, 1)
  }

  func testTimeSyncNotificationDecodes() throws {
    // struct time_status_np: master_offset, ingress_time, cumulativeScaledRateOffset,
    // scaledLastGmPhaseChange, gmTimeBaseIndicator, lastGmPhaseChange (ScaledNs),
    // gmPresent, gmIdentity
    let uds = PTP.PortIdentity(clockIdentity: _clock, portNumber: 0)
    var data = _be(Int64(-25)) + _be(Int64(1_700_000_000_000_000_000)) + _be(Int32(5))
    data += _be(Int32(0)) + _be(UInt16(1)) + [UInt8](repeating: 0, count: 12) + _be(Int32(1))
    data += [0x00, 0x1B, 0x21, 0xFF, 0xFE, 0x01, 0x02, 0x03]
    let pdu = try _notification(from: uds, managementId: 0xC000, data: data)
    guard case let .timeSync(status) = try PTPManagementEvent(notification: pdu) else {
      return XCTFail("expected a time sync event")
    }
    XCTAssertEqual(status.masterOffset, -25)
    XCTAssertEqual(status.gmPresent, 1)
    XCTAssertEqual(
      status.gmIdentity,
      PTP.ClockIdentity(id: (0x00, 0x1B, 0x21, 0xFF, 0xFE, 0x01, 0x02, 0x03))
    )
  }

  func testParentDataSetNotificationDecodes() throws {
    // struct parentDS: parentPortIdentity, parentStats, reserved,
    // observedParentOffsetScaledLogVariance, observedParentClockPhaseChangeRate,
    // grandmasterPriority1, grandmasterClockQuality, grandmasterPriority2, grandmasterIdentity
    let uds = PTP.PortIdentity(clockIdentity: _clock, portNumber: 0)
    let parent = PTP.PortIdentity(clockIdentity: _clock, portNumber: 1)
    var serializationContext = SerializationContext()
    try parent.serialize(into: &serializationContext)
    var data = serializationContext.bytes + [0, 0] + _be(UInt16(0xFFFF)) + _be(Int32(0x7FFF_FFFF))
    data += [246, 248, 0xFE, 0x43, 0x6A, 248] + [0x00, 0x1B, 0x21, 0xFF, 0xFE, 0x0A, 0x0B, 0x0C]
    let pdu = try _notification(from: uds, managementId: 0x2002, data: data)
    guard case let .parentDataSet(dataSet) = try PTPManagementEvent(notification: pdu) else {
      return XCTFail("expected a parent data set event")
    }
    XCTAssertEqual(dataSet.parentPortIdentity, parent)
    XCTAssertEqual(dataSet.grandmasterPriority1, 246)
    XCTAssertEqual(dataSet.grandmasterClockQuality.clockClass, 248)
    XCTAssertEqual(
      dataSet.grandmasterIdentity,
      PTP.ClockIdentity(id: (0x00, 0x1B, 0x21, 0xFF, 0xFE, 0x0A, 0x0B, 0x0C))
    )
  }

  func testOtherResponsesAreNotEvents() throws {
    let uds = PTP.PortIdentity(clockIdentity: _clock, portNumber: 0)
    // the reply to our own SUBSCRIBE_EVENTS_NP SET
    let reply = try _notification(
      from: uds,
      managementId: 0xC003,
      data: _be(UInt16(30)) + [0x09] + [UInt8](repeating: 0, count: 63)
    )
    XCTAssertNil(try PTPManagementEvent(notification: reply))
    // a GET request is not a notification even when it names an event's data set
    var get = try _notification(from: uds, managementId: 0xC00B, data: [])
    get[46] = 0x00
    XCTAssertNil(try PTPManagementEvent(notification: get))
  }

  // MARK: - renewal

  func testRenewalIntervalIsAThirdOfTheDuration() {
    XCTAssertEqual(PTPEventSubscriptionState(duration: 30).renewalInterval, .seconds(10))
    XCTAssertEqual(PTPEventSubscriptionState(duration: 180).renewalInterval, .seconds(60))
    // too short to renew thrice, or never expiring: clamped
    XCTAssertEqual(PTPEventSubscriptionState(duration: 0).duration, 3)
    XCTAssertEqual(PTPEventSubscriptionState(duration: 1).renewalInterval, .seconds(1))
    XCTAssertEqual(PTPEventSubscriptionState(duration: .max).duration, .max - 1)
    for duration: UInt16 in [3, 4, 30, 100, UInt16.max - 1] {
      let state = PTPEventSubscriptionState(duration: duration)
      XCTAssertLessThan(state.renewalInterval * 2, .seconds(Int(state.duration)))
    }
  }

  func testRenewalAnnouncesSubscriptionOnlyOnChange() {
    var state = PTPEventSubscriptionState(duration: 30)
    XCTAssertFalse(state.needsProbe) // nothing to probe before the first SET

    XCTAssertEqual(
      state.renewed(wasHeld: false),
      .init(transition: .subscribed, delay: .seconds(10))
    )
    XCTAssertTrue(state.needsProbe)
    XCTAssertEqual(state.renewed(wasHeld: true), .init(transition: nil, delay: .seconds(10)))
    XCTAssertEqual(state.renewed(wasHeld: true), .init(transition: nil, delay: .seconds(10)))
  }

  func testRestartBetweenRenewalsResubscribes() {
    // ptp4l restarted within one renewal interval: it answers, but has forgotten us
    var state = PTPEventSubscriptionState(duration: 30)
    _ = state.renewed(wasHeld: false)
    XCTAssertEqual(
      state.renewed(wasHeld: false),
      .init(transition: .subscribed, delay: .seconds(10))
    )
    XCTAssertTrue(state.isSubscribed)
  }

  func testUnreachablePtp4lIsRetriedEverySecond() {
    var state = PTPEventSubscriptionState(duration: 30)
    // not up yet at start: retried quietly
    XCTAssertEqual(state.failed(), .init(transition: nil, delay: .seconds(1)))
    XCTAssertEqual(state.renewed(wasHeld: false).transition, .subscribed)
    // one missed renewal is retried without giving the subscription up: ptp4l still holds it
    XCTAssertEqual(state.failed(), .init(transition: nil, delay: .seconds(1)))
    XCTAssertTrue(state.needsProbe)
    XCTAssertEqual(state.renewed(wasHeld: true), .init(transition: nil, delay: .seconds(10)))
    // stopped: announced on the second miss in a row, then retried quietly until it answers
    XCTAssertEqual(state.failed(), .init(transition: nil, delay: .seconds(1)))
    XCTAssertEqual(state.failed(), .init(transition: .unsubscribed, delay: .seconds(1)))
    XCTAssertFalse(state.needsProbe)
    XCTAssertEqual(state.failed(), .init(transition: nil, delay: .seconds(1)))
    XCTAssertEqual(
      state.renewed(wasHeld: false),
      .init(transition: .subscribed, delay: .seconds(10))
    )
  }
}
