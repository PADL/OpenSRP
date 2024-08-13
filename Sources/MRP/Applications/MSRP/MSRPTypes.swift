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

enum MSRPPortMediaType {
  case accessControlPort
  case nonDMNSharedMediumPort
}

enum MSRPDirection {
  case talker
  case listener
}

enum MSRPDeclarationType {
  case talkerAdvertise
  case talkerFailed
  case listenerAskingFailed
  case listenerReady
  case listenerReadyFailed
}

typealias MSRPTrafficClass = Int
typealias MSRPPortLatency = Int
public typealias MSRPSRClass = UInt8

enum MSRPProtocolVersion: ProtocolVersion {
  case v0 = 0
  case v1 = 1
}

struct MSRPPortParameters {
  let enabled: Bool
  let tcMaxLatency: [MSRPTrafficClass: MSRPPortLatency]
  let streamAge: UInt32
  let srpDomainBoundaryPort: [MSRPSRClass: Bool]
  let neighborProtocolVersion: MSRPProtocolVersion
  let talkerPruning: Bool
  let talkerVlanPruning: Bool
}
