//
// Copyright (c) 2024-2026 PADL Software Pty Ltd
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
    case startLeaveAllTimer
    case sLA
  }

  // initializing _state to .Passive and starting leavealltimer is equivalent
  // to handling the .Begin event
  private let _state = Mutex(State.Passive)
  private let _leaveAllTime: Duration
  private let _leaveAllTimer: Timer

  init(interval leaveAllTime: Duration, onLeaveAllTimerExpired: @escaping Timer.Action) {
    _leaveAllTime = leaveAllTime
    _leaveAllTimer = Timer(label: "leaveAllTimer", onExpiry: onLeaveAllTimerExpired)
    if _leaveAllTime != Duration.zero {
      let randomizedInterval = _randomizeLeaveAllTime(leaveAllTime)
      _leaveAllTimer.start(interval: randomizedInterval)
    }
  }

  func action(for event: ProtocolEvent) -> (Action?, Bool) {
    _state.withLock { state in
      state.action(for: event)
    }
  }

  var state: State { _state.withLock { $0 } }

  func startLeaveAllTimer() {
    let randomizedInterval = _randomizeLeaveAllTime(_leaveAllTime)
    _leaveAllTimer.start(interval: randomizedInterval)
  }

  private func _randomizeLeaveAllTime(_ baseTime: Duration) -> Duration {
    let baseSeconds = baseTime / .seconds(1)
    let randomizedSeconds = Double.random(in: baseSeconds..<(1.5 * baseSeconds))
    return Duration.seconds(randomizedSeconds)
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
  ) -> (LeaveAll.Action?, Bool) {
    let action: LeaveAll.Action?
    var txOpportunity = false

    switch event {
    case .Begin:
      action = .startLeaveAllTimer
      self = .Passive
    case .Flush:
      action = .startLeaveAllTimer
      self = .Passive
    case .tx:
      guard self == .Active else {
        action = nil
        break
      }
      action = .sLA
      self = .Passive
    case .rLA:
      action = .startLeaveAllTimer
      self = .Passive
    case .leavealltimer:
      action = .startLeaveAllTimer
      // 10-5: Request opportunity to transmit on entry to the Active state
      txOpportunity = self == .Passive
      self = .Active
    default:
      action = nil
    }

    return (action, txOpportunity)
  }
}
