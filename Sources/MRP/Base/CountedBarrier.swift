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

import Synchronization

// A counting barrier: callers await `waitUntilZero()` and resume the moment the
// count next falls to zero. `count` is a lone atomic so `enter` (the hot path)
// takes no lock; the mutex guards only the waiter list. The settling `leave`
// decrements to zero then drains under the lock, and `waitUntilZero` re-reads the
// count under the same lock, so a waiter is never lost and never leaks. Each
// continuation resumes exactly once, so an unchecked continuation is safe.
final class CountedBarrier: Sendable {
  private let _count = Atomic<Int>(0)
  private let _waiters = Mutex<[UnsafeContinuation<(), Never>]>([])

  var count: Int { _count.load(ordering: .relaxed) }

  func enter() {
    _count.wrappingAdd(1, ordering: .relaxed)
  }

  func leave() {
    let remaining = _count.wrappingSubtract(1, ordering: .relaxed).newValue
    precondition(remaining >= 0)
    guard remaining == 0 else { return }
    let woken = _waiters.withLock { waiters -> [UnsafeContinuation<(), Never>] in
      let snapshot = waiters
      waiters.removeAll()
      return snapshot
    }
    for continuation in woken {
      continuation.resume()
    }
  }

  func waitUntilZero() async {
    await withUnsafeContinuation { continuation in
      let drained = _waiters.withLock { waiters -> Bool in
        if _count.load(ordering: .relaxed) == 0 { return true }
        waiters.append(continuation)
        return false
      }
      if drained { continuation.resume() }
    }
  }
}
