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

public protocol Port: Hashable, Sendable, Identifiable {
  associatedtype ID = Int

  var isOperational: Bool { get }
  var isEnabled: Bool { get }
  var isPointToPoint: Bool { get }

  var name: String { get }
  var id: ID { get }
  var vid: UInt16? { get }

  var macAddress: EUI48 { get }

  func addFilter(for macAddress: EUI48, etherType: UInt16) throws
  func removeFilter(for macAddress: EUI48, etherType: UInt16) throws

  func tx(_ packet: IEEE802Packet) async throws
  var rxPackets: AnyAsyncSequence<IEEE802Packet> { get async throws }
}

public enum PortNotification<P: Port>: Sendable {
  case added(P)
  case removed(P)
  case changed(P)

  var port: P {
    switch self {
    case let .added(port):
      port
    case let .removed(port):
      port
    case let .changed(port):
      port
    }
  }
}

extension Port {
  func tx(
    pdu: MRPDU,
    for application: some Application,
    contextIdentifier: MAPContextIdentifier
  ) async throws {
    let packet = try IEEE802Packet(
      destMacAddress: application.groupMacAddress,
      contextIdentifier: contextIdentifier,
      sourceMacAddress: macAddress,
      etherType: application.etherType,
      data: pdu.serialized()
    )
    try await tx(packet)
  }
}

public protocol Bridge<P>: Sendable {
  associatedtype P: Port

  var ports: [P] { get async throws }
  var notifications: AnyAsyncSequence<PortNotification<P>> { get }
}

extension Bridge {
  func port(name: String) async throws -> P {
    guard let port = try await ports.first(where: { $0.name == name }) else {
      throw MRPError.portNotFound
    }
    return port
  }

  func port(id: P.ID) async throws -> P {
    guard let port = try await ports.first(where: { $0.id == id }) else {
      throw MRPError.portNotFound
    }
    return port
  }
}
