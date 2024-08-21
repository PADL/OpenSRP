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
import IEEE802

public protocol Bridge<P>: Sendable {
  associatedtype P: Port

  var notifications: AnyAsyncSequence<PortNotification<P>> { get }

  func register(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<P>
  ) async throws
  func deregister(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<P>
  ) async throws

  func run(controller: isolated MRPController<P>) async throws
  func shutdown(controller: isolated MRPController<P>) async throws

  // Bridge provies a unified interface for sending and receiving packets, even
  // though the actual implementation may need separate paths for handling link-
  // local and non-link-local packets
  func getVlans(controller: isolated MRPController<P>) async -> Set<VLAN>

  func tx(_ packet: IEEE802Packet, on: P.ID, controller: isolated MRPController<P>) async throws
  var rxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)> { get throws }
}

extension Bridge {
  func tx(
    pdu: MRPDU,
    for application: some Application,
    contextIdentifier: MAPContextIdentifier,
    on port: P,
    controller: isolated MRPController<P>
  ) async throws {
    var serializationContext = SerializationContext()
    try pdu.serialize(into: &serializationContext, application: application)

    let packet = IEEE802Packet(
      destMacAddress: application.groupAddress,
      contextIdentifier: contextIdentifier,
      sourceMacAddress: port.macAddress,
      etherType: application.etherType,
      payload: serializationContext.bytes
    )
    try await tx(packet, on: port.id, controller: controller)
  }
}
