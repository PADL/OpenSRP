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

/*
 The job of the Registrar is to record declarations of the attribute made by other Participants on the LAN. It does not send any protocol messages, as the Applicant looks after the interests of all would-be Participants.
 */
struct Registrar: Sendable, CustomStringConvertible {
  enum State: Sendable, StateMachineHandler {
    case IN // Registered
    case LV // Previously registered, but now being timed out
    case MT // Not registered
  }

  private let _state = ManagedCriticalState(State.MT)
  private var _leavetimer: Timer!

  init(onLeaveTimerExpired: @escaping Timer.Action) {
    _leavetimer = Timer(onExpiry: onLeaveTimerExpired)
  }

  func handle(event: ProtocolEvent, flags: StateMachineHandlerFlags) -> [ProtocolAction] {
    _state.withCriticalRegion { $0.handle(event: event, flags: flags) }
  }

  var state: State { _state.criticalState }

  func startLeaveTimer() {
    _leavetimer.start(interval: LeaveTime)
  }

  func stopLeaveTimer() {
    _leavetimer.stop()
  }

  var description: String {
    String(describing: _state.criticalState)
  }
}

/*
 b) A per-Attribute Registrar state machine (10.7.8)

 A Full Participant implements the Registrar state machine (Table 10-4) for each Attribute declared, registered, or tracked.

 The job of the Registrar is to record declarations of the attribute made by other Participants on the LAN. It does not send any protocol messages, as the Applicant looks after the interests of all would-be Participants.
 */

extension Registrar.State {
  mutating func handle(
    event: ProtocolEvent,
    flags: StateMachineHandlerFlags
  ) -> [ProtocolAction] {
    var actions = [ProtocolAction]()

    if flags.contains(.registrationForbidden) {
      self = .MT
      return actions
    }
    if (flags.contains(.registrationFixedNewPropagated) && event != .rNew) ||
      flags.contains(.registrationFixedNewIgnored)
    {
      return actions
    }

    switch event {
    case .Begin:
      self = .MT
    case .rNew:
      fallthrough
    case .rJoinIn:
      fallthrough
    case .rJoinMt:
      if event == .rNew {
        actions.append(.New)
      } else if self == .MT {
        actions.append(.Join)
      }
      if self == .LV {
        actions.append(.leavetimer)
      }
      self = .IN
    case .rLv:
      fallthrough
    case .rLA:
      fallthrough
    case .txLA:
      fallthrough
    case .ReDeclare:
      precondition(self == .IN)
      actions = [.leavetimer]
      self = .LV
    case .Flush:
      if self != .MT {
        actions.append(.Lv)
      }
      self = .MT
    case .leavetimer:
      precondition(self != .IN)
      if self == .LV || flags.contains(.operPointToPointMAC) {
        actions = [.Lv]
      }
      self = .MT
    default:
      break
    }

    return actions
  }
}
