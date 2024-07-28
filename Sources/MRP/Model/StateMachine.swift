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

struct StateMachineHandlerFlags: OptionSet {
  typealias RawValue = UInt32

  var rawValue: RawValue

  init(rawValue: RawValue) {
    self.rawValue = rawValue
  }

  static let operPointToPointMAC = StateMachineHandlerFlags(rawValue: 1 << 0)
  static let registrationFixedNewIgnored = StateMachineHandlerFlags(rawValue: 1 << 1)
  static let registrationFixedNewPropagated = StateMachineHandlerFlags(rawValue: 1 << 2)
  static let registrationForbidden = StateMachineHandlerFlags(rawValue: 1 << 3)
  static let applicantOnlyParticipant = StateMachineHandlerFlags(rawValue: 1 << 4)
}

protocol StateMachineHandler: Sendable {
  mutating func handle(event: ProtocolEvent, flags: StateMachineHandlerFlags) -> [ProtocolAction]
}
