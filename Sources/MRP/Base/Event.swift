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

// The following conventions are used in the abbreviations used in this
// subclause:
// rXXX receive PDU XXX
// sXXX send PDU XXX
// txXXX transmit opportunity
// XXX! state machine event
// !XXX “Not XXX”; i.e., logical NOT applied to the condition XXX

public enum ProtocolEvent: Sendable {
  case Begin // Initialize state machine (10.7.5.1)
  case New // A new declaration (10.7.5.4)
  case Join // Declaration without signaling new registration (10.7.5.5)
  case Lv // Withdraw a declaration (10.7.5.6)
  case tx // Transmission opportunity without a LeaveAll (10.7.5.7)
  case txLA // Transmission opportunity with a LeaveAll (10.7.5.8)
  case txLAF // Transmission opportunity with a LeaveAll, and with no room (Full) (10.7.5.9)
  case rNew // receive New message (10.7.5.14)
  case rJoinIn // receive JoinIn message (10.7.5.15)
  case rIn // receive In message (10.7.5.18)
  case rJoinMt // receive JoinEmpty message (10.7.5.16)
  case rMt // receive Empty message (10.7.5.19)
  case rLv // receive Leave message (10.7.5.17)
  case rLA // receive a LeaveAll message (10.7.5.20)
  case Flush // Port role changes from Root Port or Alternate Port to Designated Port (10.7.5.2)
  case ReDeclare // Port role changes from Designated to Root Port or Alternate Port (10.7.5.3)
  case periodic // A periodic transmission event occurs (10.7.5.10)
  case leavetimer // leavetimer has expired (10.7.5.21)
  case leavealltimer // leavealltimer has expired (10.7.5.22)
  case periodictimer // periodictimer has expired (10.7.5.23)

  fileprivate var _r: Bool {
    switch self {
    case .rNew:
      fallthrough
    case .rJoinIn:
      fallthrough
    case .rIn:
      fallthrough
    case .rJoinMt:
      fallthrough
    case .rMt:
      fallthrough
    case .rLv:
      fallthrough
    case .rLA:
      return true
    default:
      return false
    }
  }
}

public struct EventContext<A: Application>: Sendable, CustomStringConvertible {
  public let participant: Participant<A>
  public let event: ProtocolEvent
  public let eventSource: EventSource
  public let attributeType: AttributeType
  public let attributeSubtype: AttributeSubtype?
  public let attributeValue: any Value

  let smFlags: StateMachineHandlerFlags
  let applicant: Applicant
  let registrar: Registrar?

  public var description: String {
    "EventContext(event: \(event), eventSource: \(eventSource), attributeType: \(attributeType), attributeSubtype: \(attributeSubtype ?? 0), attributeValue: \(attributeValue), smFlags: \(smFlags), state A \(applicant) R \(registrar?.description ?? "-"))"
  }
}

public enum EventSource: Sendable {
  // event source was join timer
  case joinTimer
  // event source was leave timer
  case leaveTimer
  // event source was leave all timer
  case leaveAllTimer
  // event source was periodic timer
  case periodicTimer
  // event source was the local port (e.g. kernel MVRP)
  case local
  // event source was a remote peer
  case peer
  // event source was explicit administrative control (e.g. TSN endpoint)
  case `internal`
  // event source was transitive via MAP function
  case map
  // event source was a preApplicantEventHandler/postApplicantEventHandler hook
  case application
  // event source was immediate re-registration after LeaveAll processing
  case leaveAll
}

struct StateMachineHandlerFlags: OptionSet, CustomStringConvertible {
  typealias RawValue = UInt32

  var rawValue: RawValue

  init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  var description: String {
    var flags = [String]()

    if contains(.operPointToPointMAC) { flags.append("operPointToPointMAC") }
    if contains(.registrationFixedNewIgnored) { flags.append("registrationFixedNewIgnored") }
    if contains(.registrationFixedNewPropagated) { flags.append("registrationFixedNewPropagated") }
    if contains(.registrationForbidden) { flags.append("registrationForbidden") }
    if contains(.applicantOnlyParticipant) { flags.append("applicantOnlyParticipant") }

    return "[" + flags.joined(separator: ", ") + "]"
  }

  static let operPointToPointMAC = StateMachineHandlerFlags(rawValue: 1 << 0)
  static let registrationFixedNewIgnored = StateMachineHandlerFlags(rawValue: 1 << 1)
  static let registrationFixedNewPropagated = StateMachineHandlerFlags(rawValue: 1 << 2)
  static let registrationForbidden = StateMachineHandlerFlags(rawValue: 1 << 3)
  static let applicantOnlyParticipant = StateMachineHandlerFlags(rawValue: 1 << 4)
}

public struct EventCounters<A: Application>: Sendable {
  var newMessagesSent = 0
  var joinInMessagesSent = 0
  var joinEmptyMessagesSent = 0
  var joinInMessagesReceived = 0
  var didReceiveLeaveAllMessage = false
  var didReceiveLeaveMessage = false

  // clause 10.6: count messages received and sent
  mutating func count(context: EventContext<A>, attributeEvent: AttributeEvent?) {
    if context.event._r {
      didReceiveLeaveMessage = context.event == .rLv
      didReceiveLeaveAllMessage = context.event == .rLA
      if context.event == .rJoinIn { joinInMessagesReceived += 1 }
    }

    if let attributeEvent {
      switch attributeEvent {
      case .New:
        newMessagesSent += 1
      case .JoinIn:
        joinInMessagesSent += 1
      case .JoinMt:
        joinEmptyMessagesSent += 1
      default:
        break
      }
    }
  }
}
