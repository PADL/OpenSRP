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

import Locking

// The job of the Registrar is to record declarations of the attribute made by
// other Participants on the LAN. It does not send any protocol messages, as
// the Applicant looks after the interests of all would-be Participants.

struct Registrar: Sendable, CustomStringConvertible {
  enum State: Sendable {
    case IN // Registered
    case LV // Previously registered, but now being timed out
    case MT // Not registered
  }

  enum Action: Sendable {
    case New // send a New indication to MAP and the MRP application (10.7.6.12)
    case Join // send a Join indication to MAP and the MRP application (10.7.6.13)
    case Lv // send a Lv indication to MAP and the MRP application (10.7.6.14)
  }

  private let _state = ManagedCriticalState(State.MT)
  private var _leavetimer: Timer!

  init(onLeaveTimerExpired: @escaping Timer.Action) {
    _leavetimer = Timer(onExpiry: onLeaveTimerExpired)
  }

  // note: this function has side effects, it will start/stop leavetimer
  func action(for event: ProtocolEvent, flags: StateMachineHandlerFlags) -> Action? {
    _state.withCriticalRegion { state in
      if state == .LV, event == .rNew || event == .rJoinIn || event == .rJoinMt {
        stopLeaveTimer()
      } else if state == .IN,
                event == .rLv || event == .rLA || event == .txLA || event == .ReDeclare
      {
        startLeaveTimer()
      }
      return _state.withCriticalRegion { $0.action(for: event, flags: flags) }
    }
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
      flags.contains(.registrationFixedNewIgnored)
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
      precondition(self == .IN)
      self = .LV
    case .Flush:
      if self != .MT {
        action = .Lv
      }
      self = .MT
    case .leavetimer:
      precondition(self != .IN)
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
