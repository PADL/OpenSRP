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

public protocol Bridge<P>: Sendable, VLANConfiguring {
  associatedtype P: Port

  var vlans: Set<VLAN> { get }
  var notifications: AnyAsyncSequence<PortNotification<P>> { get }

  func register(groupAddress: EUI48, etherType: UInt16) throws
  func deregister(groupAddress: EUI48, etherType: UInt16) throws

  func getPorts() async throws -> Set<P>

  // Bridge provies a unified interface for sending and receiving packets, even
  // though the actual implementation may need separate paths for handling link-
  // local and non-link-local packets

  func tx(_ packet: IEEE802Packet, on: P.ID) async throws
  var rxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)> { get throws }
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

extension Bridge {
  func tx(
    pdu: MRPDU,
    for application: some Application,
    contextIdentifier: MAPContextIdentifier,
    on port: P
  ) async throws {
    let packet = try IEEE802Packet(
      destMacAddress: application.groupAddress,
      contextIdentifier: contextIdentifier,
      sourceMacAddress: port.macAddress,
      etherType: application.etherType,
      payload: pdu.serialized()
    )
    try await tx(packet, on: port.id)
  }
}
