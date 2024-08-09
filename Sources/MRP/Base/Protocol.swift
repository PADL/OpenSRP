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

// The following conventions are used in the abbreviations used in this
// subclause:
// rXXX receive PDU XXX
// sXXX send PDU XXX
// txXXX transmit opportunity
// XXX! state machine event
// !XXX “Not XXX”; i.e., logical NOT applied to the condition XXX

enum ProtocolEvent: Sendable {
  case Begin // Initialize state machine (10.7.5.1)
  case New // A new declaration (10.7.5.4)
  case Join // Declaration without signaling new registration (10.7.5.5)
  case Lv // Withdraw a declaration (10.7.5.6)
  case tx // Transmission opportunity without a LeaveAll (10.7.5.7)
  case txLA // Transmission opportunity with a LeaveAll (10.7.5.8)
  case txLAF // Transmission opportunity with a LeaveAll, and with no room (Full) (10.7.5.9)
  case rNew // receive New message (10.7.5.14)
  case rJoinIn // receive JoinIn message (10.7.5.15)
  case rIn // receive In message (10.7.5.18)
  case rJoinMt // receive JoinEmpty message (10.7.5.16)
  case rMt // receive Empty message (10.7.5.19)
  case rLv // receive Leave message (10.7.5.17)
  case rLA // receive a LeaveAll message (10.7.5.20)
  case Flush // Port role changes from Root Port or Alternate Port to Designated Port (10.7.5.2)
  case ReDeclare // Port role changes from Designated to Root Port or Alternate Port (10.7.5.3)
  case periodic // A periodic transmission event occurs (10.7.5.10)
  case leavetimer // leavetimer has expired (10.7.5.21)
  case leavealltimer // leavealltimer has expired (10.7.5.22)
  case periodictimer // periodictimer has expired (10.7.5.23)
}
