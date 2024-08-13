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

enum MSRPAttributeType: AttributeType, CaseIterable {
  // Talker Advertise Vector (25 octets)
  case talkerAdvertise = 1
  // Talker Failed Vector (34 octets)
  case talkerFailed = 2
  // Listener Vector (8 octets)
  case listener = 3
  // Domain Vector (4 octets)
  case domain = 4
  // Talker Enhanced Vector (variable)
  case talkerEnhanced = 5 // v1 only
  // Listener Enhanced Vector (variable)
  case listenerEnhanced = 6 // v1 only

  static var validAttributeTypes: ClosedRange<AttributeType> {
    allCases.first!.rawValue...allCases.last!.rawValue
  }
}

enum MSRPApplicationEvent: ApplicationEvent {
  case ignore = 0
  case askignFailed = 1
  case ready = 2
  case readyFailed = 3
}
