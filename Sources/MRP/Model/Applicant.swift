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

import Synchronization

// A Full Participant implements the complete Applicant state machine (Table 10-3)
//
// The job of the Applicant is twofold:
// a) To ensure that this Participant’s declaration is correctly registered by
// other Participants’ Registrars.  b) To prompt other Participants to
// reregister after one withdraws a declaration.
//
// The Applicant state machine distinguishes between Active Participants (that
// have sent a message or messages to make a declaration), Passive Participants
// (that require registration, but have not had to declare the attribute so far
// to register it, and will not have to explicitly deregister), and Observers
// (that do not require registration at present, but track the attribute’s
// registration in case they do and become Passive Participants).
//
// The Applicant for each Attribute implements states that record whether it
// wishes to make a new declaration, to maintain or withdraw an existing
// declaration, or has no declaration to make. It also records whether it has
// actively made a declaration, or has been passive, taking advantage of or
// simply observing the declarations of others. It counts the New, JoinIn, and
// JoinEmpty messages it has sent, and JoinIn messages sent by others, to
// ensure that at least two such messages have been sent since it last received
// a LeaveAll or Leave message, and at least one since it last received a
// JoinEmpty or Empty message. This ensures that each of the other
// Participant’s Registrars for the Attribute either have received (assuming no
// packet loss) two Join or New messages or have reported the Attribute as
// registered

final class Applicant: Sendable, CustomStringConvertible {
  enum State: Sendable {
    case VO // Very anxious Observer
    case VP // Very anxious Passive
    case VN // Very anxious New
    case AN // Anxious New
    case AA // Anxious Active
    case QA // Quiet Active
    case LA // Leaving Active
    case AO // Anxious Observer
    case QO // Quiet Observer
    case AP // Anxious Passive
    case QP // Quiet Passive
    case LO // Leaving Observer
  }

  enum Action: Sendable {
    case sN // send a New message (10.7.6.2)
    case sJ // send a JoinIn or JoinMT message (10.7.6.3)
    case sL // send a Lv message (10.7.6.4)
    case s // send an In or an Empty message (10.7.6.5)
    case s_ // send an In or an Empty message, if required for optimization of the encoding
    case sL_ // send a Lv message, if required for optimization of the encoding (10.7.6.4)
    case sJ_ // send a Join message, if required for optimization of the encoding (10.7.6.3)

    var encodingOptional: Bool {
      self == .sJ_ || self == .sL_ || self == .s_
    }
  }

  private let _state = Mutex(State.VO)

  func action(for event: ProtocolEvent, flags: StateMachineHandlerFlags) -> Action? {
    _state.withLock { $0.action(for: event, flags: flags) }
  }

  var state: State {
    _state.withLock { $0 }
  }

  var description: String {
    String(describing: state)
  }
}

private extension Applicant.State {
  mutating func action(
    for event: ProtocolEvent,
    flags: StateMachineHandlerFlags
  ) -> Applicant.Action? {
    var action: Applicant.Action?

    switch event {
    case .Begin:
      self = .VO
    case .New:
      if self != .AN {
        self = .VN
      }
    case .Join:
      switch self {
      case .LO:
        fallthrough
      case .VO:
        self = .VP
      case .LA:
        self = .AA
      case .AO:
        self = .AP
      case .QO:
        self = .QP
      default:
        break
      }
    case .Lv:
      switch self {
      case .VP:
        self = .VO
      case .VN:
        fallthrough
      case .AN:
        fallthrough
      case .AA:
        fallthrough
      case .QA:
        self = .LA
      case .AP:
        self = .AO
      case .QP:
        self = .QO
      default:
        break
      }
    case .rNew:
      break
    case .rJoinIn:
      switch self {
      case .VO:
        // Ignored (no transition) if operPointToPointMAC is TRUE
        if !flags.contains(.operPointToPointMAC) { self = .AO }
      case .VP:
        // Ignored (no transition) if operPointToPointMAC is TRUE
        if !flags.contains(.operPointToPointMAC) { self = .AP }
      case .AA:
        self = .QA
      case .AO:
        self = .QO
      case .AP:
        self = .QP
      default:
        break
      }
    case .rIn:
      // Ignored (no transition) if operPointToPointMAC is FALSE
      if self == .QA, flags.contains(.operPointToPointMAC) { self = .AA }
    case .rJoinMt:
      fallthrough
    case .rMt:
      switch self {
      case .QA:
        self = .AA
      case .QO:
        self = .AO
      case .QP:
        self = .AP
      case .LO:
        self = .VO
      default:
        break
      }
    case .rLv:
      fallthrough
    case .rLA:
      fallthrough
    case .ReDeclare:
      switch self {
      case .AN:
        self = .VN
      case .AA:
        fallthrough
      case .QA:
        self = .VP
      case .VO:
        fallthrough
      case .AO:
        fallthrough
      case .QO:
        self = flags.contains(.applicantOnlyParticipant) ? .VO : .LO
      case .AP:
        fallthrough
      case .QP:
        self = .VP
      default:
        break
      }
    case .periodic:
      switch self {
      case .QA:
        self = .AA
      case .QP:
        self = .AP
      default:
        break
      }
    case .tx:
      fallthrough
    case .txLA:
      switch self {
      case .VO:
        action = .s_
        if event == .txLA { self = .LO }
      case .VP:
        action = event == .txLA ? .s : .sJ
        self = .AA
      case .VN:
        action = .sN
        self = .AN
      case .AN:
        action = .sN
        self = .QA
      case .AA:
        action = .sJ
        self = .QA
      case .QA:
        action = event == .txLA ? .sJ : .sJ_
      case .LA:
        if event == .txLA {
          action = .s_
          self = .LO
        } else {
          action = .sL
          self = .VO
        }
      case .AO:
        fallthrough
      case .QO:
        action = .s_
        if event == .txLA { self = .LO }
      case .AP:
        action = .sJ
        self = .QA
      case .QP:
        if event == .txLA {
          action = .sJ
          self = .QA
        } else {
          action = .s_
        }
      case .LO:
        if event == .txLA {
          action = .s_
        } else {
          action = .s
          self = .VO
        }
      }
    case .txLAF:
      switch self {
      case .VO:
        self = .LO
      case .VP:
        self = .VP
      case .VN:
        fallthrough
      case .AN:
        self = .VN
      case .AA:
        fallthrough
      case .QA:
        self = .VP
      case .LA:
        fallthrough
      case .AO:
        fallthrough
      case .QO:
        self = .LO
      case .AP:
        fallthrough
      case .QP:
        self = .VP
      case .LO:
        break
      }
    default:
      break
    }

    return action
  }
}
