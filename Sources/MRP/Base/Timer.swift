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

import Dispatch
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

// A running timer is a dispatch timer source, not a task sleeping until the deadline.
// Timers are often stopped long before they expire: a Registrar's leavetimer is started
// by every LeaveAll and stopped by the rejoin that follows within milliseconds. A
// cancelled `Task.sleep` stays enqueued, holding its task's memory, until the deadline
// it was sleeping towards (swiftlang/swift#60441), so on a bridge with many attributes
// every LeaveAll would park one per attribute per port. A cancelled source is
// unregistered at once.
final class Timer: CustomStringConvertible, Sendable {
  typealias Action = @Sendable () async throws -> ()

  /// One start of the timer: `generation` tells its source's event from that of a start
  /// or stop since.
  private struct Arm {
    let source: any DispatchSourceTimer
    let generation: UInt64
  }

  private struct State {
    var arm: Arm?
    var generation = UInt64(0)
  }

  /// Every timer's events are handled here; a handler only takes a lock and starts a task.
  private static let _queue = DispatchQueue(label: "com.padl.MRP.Timer")

  private let _label: String
  private let _onExpiry: Action
  private let _state = Mutex(State())

  var description: String {
    "Timer(\(_label))"
  }

  init(label: String, onExpiry: @escaping Action) {
    _label = label
    _onExpiry = onExpiry
  }

  func start(interval: Duration) {
    // the callback runs at the priority of whoever started the timer, as it did when
    // each start created the task that slept
    let priority = Task.currentPriority
    _state.withLock { state in
      state.arm?.source.cancel() // in case stop() was not called
      state.generation &+= 1
      let generation = state.generation
      let source = DispatchSource.makeTimerSource(queue: Self._queue)
      // weak, so that a timer its owner has released is stopped by deinit rather than
      // kept alive until it fires
      source.setEventHandler { [weak self] in
        self?._fire(generation: generation, priority: priority)
      }
      source.schedule(deadline: ._after(interval))
      source.activate()
      state.arm = Arm(source: source, generation: generation)
    }
  }

  private func _fire(generation: UInt64, priority: TaskPriority) {
    // Clear the arm before calling the callback, so isRunning returns false during the
    // callback execution. An event from a start that has since been superseded is ignored.
    let isCurrent = _state.withLock { state in
      guard let arm = state.arm, arm.generation == generation else { return false }
      arm.source.cancel()
      state.arm = nil
      return true
    }
    guard isCurrent else { return }

    // Now call the callback - if it calls start(), the timer is armed again
    Task(priority: priority) {
      try await _onExpiry()
    }
  }

  func stop() {
    _state.withLock { state in
      state.arm?.source.cancel()
      state.arm = nil
      state.generation &+= 1
    }
  }

  deinit {
    stop()
  }

  var isRunning: Bool {
    _state.withLock { $0.arm != nil }
  }
}

private extension DispatchTime {
  /// `interval` from now. Computed in 64-bit nanoseconds, because
  /// `DispatchTimeInterval.nanoseconds` takes an `Int`, which on a 32-bit platform
  /// overflows after about two seconds.
  static func _after(_ interval: Duration) -> DispatchTime {
    let now = DispatchTime.now()
    guard interval > .zero else { return now }
    let (seconds, attoseconds) = interval.components
    let (wholeSeconds, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
    let (nanoseconds, subsecondOverflow) = wholeSeconds
      .addingReportingOverflow(UInt64(attoseconds / 1_000_000_000))
    let (deadline, lateOverflow) = now.uptimeNanoseconds.addingReportingOverflow(nanoseconds)
    guard !overflow, !subsecondOverflow, !lateOverflow else { return .distantFuture }
    return DispatchTime(uptimeNanoseconds: deadline)
  }
}
