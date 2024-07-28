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

struct IEEE802Packet: Sendable {
  let sourceMacAddress: EUI48
  let destMacAddress: EUI48
  let etherType: UInt16
  let data: [UInt8]
}

protocol Port: AnyObject, Hashable, Sendable, Identifiable {
  associatedtype ID = Int

  var isOperational: Bool { get }
  var isEnabled: Bool { get }
  var isPointToPoint: Bool { get }

  var name: String { get }
  var id: ID { get }

  var macAddress: EUI48 { get }

  func addFilter(for macAddress: EUI48, etherType: UInt16) throws
  func removeFilter(for macAddress: EUI48, etherType: UInt16) throws

  func tx(_ packet: IEEE802Packet) async throws
  var rxPackets: AnyAsyncSequence<IEEE802Packet> { get }
}

enum PortObservation<P: Port>: Sendable {
  case added(P)
  case removed(P)
  case changed(P)
}

typealias PortObserver<P: Port> = AnyAsyncSequence<PortObservation<P>>

extension Port {
  func tx(pdu: MRPDU, for application: some Application) async throws {
    let packet = try IEEE802Packet(
      sourceMacAddress: macAddress,
      destMacAddress: application.groupMacAddress,
      etherType: application.etherType,
      data: pdu.serialized()
    )
    try await tx(packet)
  }
}
