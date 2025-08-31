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

final class LeaveAll: Sendable, CustomStringConvertible {
  enum State {
    case Active
    case Passive
  }

  enum Action {
    case leavealltimer
    case sLA
  }

  private let _state = Mutex(State.Passive)
  private let _leaveAllTime: Duration
  private let _leaveAllTimer: Timer

  init(interval leaveAllTime: Duration, onLeaveAllTimerExpired: @escaping Timer.Action) {
    _leaveAllTime = leaveAllTime
    _leaveAllTimer = Timer(label: "leaveAllTimer", onExpiry: onLeaveAllTimerExpired)
    if _leaveAllTime != Duration.zero {
      _leaveAllTimer.start(interval: leaveAllTime)
    }
  }

  func action(for event: ProtocolEvent) -> Action? {
    _state.withLock { state in
      state.action(for: event)
    }
  }

  var state: State { _state.withLock { $0 } }

  func startLeaveAllTimer() {
    _leaveAllTimer.start(interval: _leaveAllTime)
  }

  func stopLeaveAllTimer() {
    _leaveAllTimer.stop()
  }

  var description: String {
    String(describing: state)
  }
}

private extension LeaveAll.State {
  mutating func action(
    for event: ProtocolEvent
  ) -> LeaveAll.Action? {
    let action: LeaveAll.Action

    switch event {
    case .Begin:
      action = .leavealltimer
      self = .Passive
    case .Flush:
      action = .leavealltimer
      self = .Passive
    case .tx:
      guard self == .Active else { return nil }
      action = .sLA
      self = .Passive
    case .rLA:
      action = .leavealltimer
      self = .Passive
    case .leavealltimer:
      action = .leavealltimer
      self = .Active
    default:
      return nil
    }

    return action
  }
}
