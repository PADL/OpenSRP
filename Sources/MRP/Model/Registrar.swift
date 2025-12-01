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

// The job of the Registrar is to record declarations of the attribute made by
// other Participants on the LAN. It does not send any protocol messages, as
// the Applicant looks after the interests of all would-be Participants.

final class Registrar: Sendable, CustomStringConvertible {
  enum State: Sendable {
    case IN // Registered
    case LV // Previously registered, but now being timed out
    case MT // Not registered

    var isRegistered: Bool { self != .MT }
  }

  enum Action: Sendable {
    case New // send a New indication to MAP and the MRP application (10.7.6.12)
    case Join // send a Join indication to MAP and the MRP application (10.7.6.13)
    case Lv // send a Lv indication to MAP and the MRP application (10.7.6.14)
  }

  private let _state = Mutex(State.MT)
  private let _leavetimer: Timer

  init(onLeaveTimerExpired: @escaping Timer.Action) {
    _leavetimer = Timer(label: "leavetimer", onExpiry: onLeaveTimerExpired)
  }

  // note: this function has side effects, it will start/stop leavetimer
  func action(for event: ProtocolEvent, flags: StateMachineHandlerFlags) -> Action? {
    enum LeaveTimerAction { case none; case start; case stop }

    let (leaveTimerAction, stateAction) = _state.withLock { state in
      var leaveTimerAction = LeaveTimerAction.none

      if state == .LV, event == .rNew || event == .rJoinIn || event == .rJoinMt {
        leaveTimerAction = .stop
      } else if state == .IN,
                event == .rLv || event == .rLA || event == .txLA || event == .ReDeclare
      {
        leaveTimerAction = .start
      }

      return (leaveTimerAction, state.action(for: event, flags: flags))
    }

    switch leaveTimerAction {
    case .start:
      startLeaveTimer()
    case .stop:
      stopLeaveTimer()
    default:
      break
    }

    return stateAction
  }

  var state: State { _state.withLock { $0 } }

  func startLeaveTimer() {
    _leavetimer.start(interval: LeaveTime)
  }

  func stopLeaveTimer() {
    _leavetimer.stop()
  }

  var description: String {
    String(describing: state)
  }
}

// b) A per-Attribute Registrar state machine (10.7.8)
//
// A Full Participant implements the Registrar state machine (Table 10-4) for
// each Attribute declared, registered, or tracked.
//
// The job of the Registrar is to record declarations of the attribute made by
// other Participants on the LAN. It does not send any protocol messages, as
// the Applicant looks after the interests of all would-be Participants.

private extension Registrar.State {
  mutating func action(
    for event: ProtocolEvent,
    flags: StateMachineHandlerFlags
  ) -> Registrar.Action? {
    if flags.contains(.registrationForbidden) {
      self = .MT
      return nil
    }
    if (flags.contains(.registrationFixedNewPropagated) && event != .rNew) ||
      (flags.contains(.registrationFixedNewIgnored) && event == .rNew)
    {
      return nil
    }

    var action: Registrar.Action?

    switch event {
    case .Begin:
      self = .MT
    case .rNew:
      fallthrough
    case .rJoinIn:
      fallthrough
    case .rJoinMt:
      if event == .rNew {
        action = .New
      } else if self == .MT {
        action = .Join
      }
      self = .IN
    case .rLv:
      fallthrough
    case .rLA:
      fallthrough
    case .txLA:
      fallthrough
    case .ReDeclare:
      if self == .IN {
        self = .LV
      }
    case .Flush:
      if self != .MT {
        action = .Lv
      }
      self = .MT
    case .leavetimer:
      if self == .IN {
        break
      }
      if self == .LV || flags.contains(.operPointToPointMAC) {
        action = .Lv
      }
      self = .MT
    default:
      break
    }

    return action
  }
}
