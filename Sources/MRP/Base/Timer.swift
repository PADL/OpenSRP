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

import AsyncAlgorithms
import Synchronization

// Timers are used in the state machine descriptions in order to cause actions
// to be taken after defined time periods have elapsed. The following
// terminology is used in the state machine descriptions to define timer states
// and the actions that can be performed upon them:
//
// a) A timer is said to be running if the most recent action to be performed
// upon it was a start.
//
// b) A running timer is said to have expired when the time period associated
// with the timer has elapsed since the most recent start action took place.
//
// c) A timer is said to be stopped if it has expired or if the most recent
// action to be performed upon it was a stop action.
//
// d) A start action sets a stopped timer to the running state, and associates/
// a time period with the timer.  This time period supersedes any periods that/
// might have been associated with the timer by previous start events.
//
// e) A stop action sets a timer to the stopped state.

final class Timer: CustomStringConvertible, Sendable {
  typealias Action = @Sendable () async throws -> ()

  private let _label: String
  private let _onExpiry: Action
  private let _task: Mutex<Task<(), Error>?>

  var description: String {
    "Timer(\(_label))"
  }

  init(label: String, onExpiry: @escaping Action) {
    _label = label
    _onExpiry = onExpiry
    _task = Mutex<Task<(), Error>?>(nil)
  }

  func start(interval: Duration) {
    precondition(interval >= .milliseconds(100))

    _task.withLock { task in
      task?.cancel() // in case stop() was not called
      task = Task<(), Error> {
        try await Task.sleep(for: interval, clock: .continuous)
        try await _fire(interval: interval)
      }
    }
  }

  private func _fire(interval: Duration) async throws {
    try await _onExpiry()
    // don't need to cancel task because we are about to return
    _task.withLock { $0 = nil }
  }

  func stop() {
    _task.withLock { task in
      task?.cancel()
      task = nil
    }
  }

  deinit {
    stop()
  }

  var isRunning: Bool {
    _task.withLock { $0 != nil }
  }
}
