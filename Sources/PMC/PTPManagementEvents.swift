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

// Events delivered by PTPManagementClient.events(_:duration:domainNumber:).
//
// ptp4l pushes a subscribed event as an unsolicited RESPONSE carrying the data set the event
// names (clock_notify_event() in clock.c, port_notify_event() in port.c):
//
//   NOTIFY_PORT_STATE      -> PORT_DATA_SET, on every port state transition
//   NOTIFY_TIME_SYNC       -> TIME_STATUS_NP, on every clock servo update
//   NOTIFY_PARENT_DATA_SET -> PARENT_DATA_SET, when the parent or grandmaster changes (>= 4.2)
//   NOTIFY_CMLDS           -> CMLDS_INFO_NP, on each peer delay update and asCapable change
//                             (>= 4.3); sent by the port, so its header names the port
public enum PTPManagementEvent: Sendable {
  // ptp4l now holds the subscription: the first time, and again after it was lost (ptp4l
  // unreachable, restarted or the subscription expired). State may have changed meanwhile,
  // so re-fetch whatever is cached from earlier events. Notifications sent right after the
  // SET may precede it in the stream.
  case subscribed
  // ptp4l missed two renewals in a row; no events arrive until the next .subscribed
  case unsubscribed
  case portState(PortDataSet)
  case timeSync(TimeStatusNP)
  case parentDataSet(ParentDataSet)
  case cmlds(portIdentity: PTP.PortIdentity, CmldsInfoNP)

  // nil for a message that is not a notification of a known event
  init?(notification message: PTP.ManagementMessage) throws {
    guard message.actionField == .response else { return nil }
    switch try message.managementTLV.data {
    case let portDataSet as PortDataSet:
      self = .portState(portDataSet)
    case let timeStatus as TimeStatusNP:
      self = .timeSync(timeStatus)
    case let parentDataSet as ParentDataSet:
      self = .parentDataSet(parentDataSet)
    case let cmldsInfo as CmldsInfoNP:
      self = .cmlds(portIdentity: message.header.sourcePortIdentity, cmldsInfo)
    default:
      return nil
    }
  }

  init?(notification buffer: [UInt8]) throws {
    let message = try buffer.withParserSpan { input in
      try PTP.ManagementMessage(parsing: &input)
    }
    try self.init(notification: message)
  }
}

// The renewal schedule of a SUBSCRIBE_EVENTS_NP subscription. Each renewal first GETs the
// subscription, so a ptp4l that restarted (and so forgot it) between renewals is noticed;
// the SET that follows re-arms it for another `duration`.
struct PTPEventSubscriptionState: Sendable, Equatable {
  // ptp4l takes a duration up to UInt16.max - 1 (UInt16.max never expires, which would
  // leave the subscription behind us); three renewals per duration need at least 3 s
  static let DurationRange: ClosedRange<UInt16> = 3...(UInt16.max - 1)
  static let RetryInterval = Duration.seconds(1)

  enum Transition: Sendable, Equatable {
    case subscribed
    case unsubscribed
  }

  struct Step: Sendable, Equatable {
    let transition: Transition?
    let delay: Duration
  }

  // renewals ptp4l may miss before the subscription is given up for lost: a single slow
  // reply on a loaded box must not cost a full resync, and ptp4l still holds it then
  static let ToleratedFailures = 1

  let duration: UInt16
  private(set) var isSubscribed = false
  private var failures = 0

  init(duration: UInt16) {
    self.duration = min(max(duration, Self.DurationRange.lowerBound), Self.DurationRange.upperBound)
  }

  // three renewals per duration, as phc2sys does (pmc_agent.c UPDATES_PER_SUBSCRIPTION), so
  // two can be lost before ptp4l expires the subscription (clock_prune_subscriptions())
  var renewalInterval: Duration {
    .seconds(Int(duration)) / 3
  }

  // whether the next renewal should first check that ptp4l still holds the subscription
  var needsProbe: Bool {
    isSubscribed
  }

  // the SET succeeded; wasHeld is what the GET before it found (false if not probed)
  mutating func renewed(wasHeld: Bool) -> Step {
    defer {
      isSubscribed = true
      failures = 0
    }
    let lost = !isSubscribed || !wasHeld
    return Step(transition: lost ? .subscribed : nil, delay: renewalInterval)
  }

  // ptp4l did not answer, or the socket failed: retry soon
  mutating func failed() -> Step {
    failures += 1
    guard isSubscribed, failures > Self.ToleratedFailures else {
      return Step(transition: nil, delay: Self.RetryInterval)
    }
    isSubscribed = false
    return Step(transition: .unsubscribed, delay: Self.RetryInterval)
  }
}
