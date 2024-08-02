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

public struct IEEE802Packet: Sendable, SerDes {
  let destMacAddress: EUI48
  let sourceMacAddress: EUI48
  let etherType: UInt16
  let data: [UInt8]

  init(destMacAddress: EUI48, sourceMacAddress: EUI48, etherType: UInt16, data: [UInt8]) {
    self.destMacAddress = destMacAddress
    self.sourceMacAddress = sourceMacAddress
    self.etherType = etherType
    self.data = data
  }

  init(
    deserializationContext: inout DeserializationContext
  ) throws {
    destMacAddress = try deserializationContext.deserialize()
    sourceMacAddress = try deserializationContext.deserialize()
    etherType = try deserializationContext.deserialize()
    data = Array(deserializationContext.deserializeRemaining())
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.reserveCapacity(2 * Int(6) + 6 + 2 + data.count)
    serializationContext.serialize(eui48: destMacAddress)
    serializationContext.serialize(eui48: sourceMacAddress)
    serializationContext.serialize(uint16: etherType)
    serializationContext.serialize(data)
  }
}

public protocol Port: Hashable, Sendable, Identifiable {
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
  var rxPackets: AnyAsyncSequence<IEEE802Packet> { get async throws }
}

public enum PortNotification<P: Port>: Sendable {
  case added(P)
  case removed(P)
  case changed(P)
}

extension Port {
  func tx(pdu: MRPDU, for application: some Application) async throws {
    let packet = try IEEE802Packet(
      destMacAddress: application.groupMacAddress,
      sourceMacAddress: macAddress,
      etherType: application.etherType,
      data: pdu.serialized()
    )
    try await tx(packet)
  }
}

public protocol PortMonitor<P>: Sendable {
  associatedtype P: Port

  var ports: [P] { get async throws }
  var notifications: AnyAsyncSequence<PortNotification<P>> { get }
}
