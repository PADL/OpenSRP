//
// Copyright (c) 2025 PADL Software Pty Ltd
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

public struct MRPTimerConfiguration: Sendable {
  // AVNU joinTime is 180-240ms, but some switches use 600ms, so allow that
  private static let ValidJoinTimes: ClosedRange<Duration> = Duration.seconds(0.1)...Duration
    .seconds(0.6)
  // AVNU leaveTime is 4.5-7.5s, but allow 1s as allowed by 802.1Q
  private static let ValidLeaveTimes: ClosedRange<Duration> = Duration.seconds(1)...Duration
    .seconds(7.5)
  // AVNU leavealltimer is 9.5-15.5s
  private static let ValidLeaveAllTimes: ClosedRange<Duration> = Duration.seconds(9.5)...Duration
    .seconds(15.5)
  // AVNU periodictimer is 900-1500ms, but allow it to be disabled by setting to zero
  private static let ValidPeriodicTimes: ClosedRange<Duration> = Duration.seconds(0.9)...Duration
    .seconds(1.5)

  public let joinTime: Duration
  public let leaveTime: Duration
  public let leaveAllTime: Duration
  public let periodicTime: Duration

  public init(
    joinTime: Duration? = nil,
    leaveTime: Duration? = nil,
    leaveAllTime: Duration? = nil,
    periodicTime: Duration? = nil
  ) {
    if joinTime == nil {
      self.joinTime = JoinTime
    } else if Self.ValidJoinTimes.contains(joinTime!) {
      self.joinTime = joinTime!
    } else {
      self.joinTime = joinTime! < Self.ValidJoinTimes.lowerBound ? Self.ValidJoinTimes
        .lowerBound : Self.ValidJoinTimes.upperBound
    }

    if leaveTime == nil {
      self.leaveTime = LeaveTime
    } else if Self.ValidLeaveTimes.contains(leaveTime!) {
      self.leaveTime = leaveTime!
    } else {
      self.leaveTime = leaveTime! < Self.ValidLeaveTimes.lowerBound ? Self.ValidLeaveTimes
        .lowerBound : Self.ValidLeaveTimes.upperBound
    }

    if leaveAllTime == .zero {
      self.leaveAllTime = .zero
    } else if leaveAllTime == nil {
      self.leaveAllTime = LeaveAllTime
    } else if Self.ValidLeaveAllTimes.contains(leaveAllTime!) {
      self.leaveAllTime = leaveAllTime!
    } else {
      self.leaveAllTime = leaveAllTime! < Self.ValidLeaveAllTimes.lowerBound ? Self
        .ValidLeaveAllTimes.lowerBound : Self.ValidLeaveAllTimes.upperBound
    }

    if periodicTime == .zero {
      self.periodicTime = .zero
    } else if periodicTime == nil {
      self.periodicTime = .seconds(1)
    } else if Self.ValidPeriodicTimes.contains(periodicTime!) {
      self.periodicTime = periodicTime!
    } else {
      self.periodicTime = periodicTime! < Self.ValidPeriodicTimes.lowerBound ? Self
        .ValidPeriodicTimes.lowerBound : Self.ValidPeriodicTimes.upperBound
    }
  }
}
