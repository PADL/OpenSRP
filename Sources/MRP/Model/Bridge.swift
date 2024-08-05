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

import AsyncExtensions

public protocol Bridge<P>: Sendable {
  associatedtype P: Port

  var vlans: Set<VLAN> { get }
  var notifications: AnyAsyncSequence<PortNotification<P>> { get }

  func getPorts() async throws -> Set<P>
}

extension Bridge {
  func port(name: String) async throws -> P {
    guard let port = try await getPorts().first(where: { $0.name == name }) else {
      throw MRPError.portNotFound
    }
    return port
  }

  func port(id: P.ID) async throws -> P {
    guard let port = try await getPorts().first(where: { $0.id == id }) else {
      throw MRPError.portNotFound
    }
    return port
  }
}
