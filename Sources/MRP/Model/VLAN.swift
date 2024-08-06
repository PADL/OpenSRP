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

public struct VLAN: Hashable, Sendable, Identifiable {
  public typealias ID = UInt16

  public var id: ID { vid }
  var vid: UInt16

  var contextIdentifier: MAPContextIdentifier {
    MAPContextIdentifier(id: vid)
  }

  public init(id: ID) {
    self.init(vid: id)
  }

  init(vid: UInt16) {
    self.vid = vid
  }

  init(contextIdentifier: MAPContextIdentifier) {
    self.init(vid: contextIdentifier.id)
  }
}

public protocol VLANConfigurator: Sendable {
  func add(vlan: VLAN) async throws
  func remove(vlan: VLAN) async throws
}
