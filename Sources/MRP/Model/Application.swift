//
// Copyright (c) 2024-2026 PADL Software Pty Ltd
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

import BinaryParsing
import IEEE802
import Logging

public enum AdministrativeControl {
  case normalParticipant // the state machine participates normally in MRP exchanges
  case newOnlyParticipant // the state machine sends only New MRP messages
  case nonParticipant // the state machine does not send any MRP messages
}

public typealias AttributeSubtype = UInt8

public protocol Application<P>: Actor, Equatable, Hashable, Sendable {
  associatedtype P: Port

  typealias ApplyFunction<T> = (Participant<Self>) throws -> T
  typealias AsyncApplyFunction<T> = (Participant<Self>) async throws -> T

  nonisolated var validAttributeTypes: ClosedRange<AttributeType> { get }
  nonisolated var groupAddress: EUI48 { get }
  nonisolated var etherType: UInt16 { get }
  nonisolated var protocolVersion: ProtocolVersion { get }
  nonisolated var hasAttributeListLength: Bool { get }
  nonisolated var name: String { get }

  nonisolated var controller: MRPController<P>? { get }

  // notifications from controller when a port is added, didUpdated or removed
  // if contextIdentifier is MAPBaseSpanningTreeContext, the ports are physical
  // ports on the bridge; otherwise, they are virtual ports managed by MVRP.
  func didAdd(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) async throws
  func didUpdate(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) async throws
  func didRemove(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) async throws

  // apply for all participants. if contextIdentifier is nil, then all participants are called
  // regardless of contextIdentifier.
  @discardableResult
  func apply<T>(
    for contextIdentifier: MAPContextIdentifier?,
    _ block: ApplyFunction<T>
  ) rethrows -> [T]

  @discardableResult
  func apply<T>(
    for contextIdentifier: MAPContextIdentifier?,
    _ block: AsyncApplyFunction<T>
  ) async rethrows -> [T]

  nonisolated func hasAttributeSubtype(for: AttributeType) -> Bool
  nonisolated func administrativeControl(for: AttributeType) throws -> AdministrativeControl
  nonisolated var nonBaseContextsSupported: Bool { get }

  nonisolated func makeNullValue(for attributeType: AttributeType) throws -> any Value
  nonisolated func deserialize(
    attributeOfType attributeType: AttributeType,
    from input: inout ParserSpan
  ) throws -> any Value

  func joinIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) async throws

  func leaveIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: EventSource
  ) async throws

  func periodic(for contextIdentifier: MAPContextIdentifier?) async throws
}

public extension Application {
  nonisolated func hash(into hasher: inout Hasher) {
    etherType.hash(into: &hasher)
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.etherType == rhs.etherType
  }
}

extension Application {
  typealias ParticipantSpecificApplyFunction<T> = (Participant<Self>) -> (T) throws -> ()
  typealias AsyncParticipantSpecificApplyFunction<T> = (Participant<Self>) -> (T) async throws -> ()

  private func apply<T>(
    for contextIdentifier: MAPContextIdentifier,
    with arg: T,
    _ block: ParticipantSpecificApplyFunction<T>
  ) throws {
    try apply(for: contextIdentifier) { participant in
      try block(participant)(arg)
    }
  }

  func findParticipants(for contextIdentifier: MAPContextIdentifier? = nil)
    -> [Participant<Self>]
  {
    apply(for: contextIdentifier) { $0 }
  }

  func findParticipant(
    for contextIdentifier: MAPContextIdentifier? = nil,
    port: P
  ) throws -> Participant<Self> {
    guard let participant = findParticipants(for: contextIdentifier)
      .first(where: { $0.port == port })
    else {
      throw MRPError.participantNotFound
    }
    return participant
  }

  func join(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype? = nil,
    attributeValue: some Value,
    isNew: Bool,
    for contextIdentifier: MAPContextIdentifier
  ) throws {
    try apply(for: contextIdentifier) { participant in
      try participant.join(
        attributeType: attributeType,
        attributeSubtype: attributeSubtype,
        attributeValue: attributeValue,
        isNew: isNew,
        eventSource: .application
      )
    }
  }

  func leave(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype? = nil,
    attributeValue: some Value,
    for contextIdentifier: MAPContextIdentifier
  ) throws {
    try apply(for: contextIdentifier) { participant in
      try participant.leave(
        attributeType: attributeType,
        attributeSubtype: attributeSubtype,
        attributeValue: attributeValue,
        eventSource: .application
      )
    }
  }

  func rx(packet: IEEE802Packet, from port: P) throws {
    let pdu = try packet.payload.withParserSpan { input in
      try MRPDU(parsing: &input, application: self)
    }
    try rx(
      pdu: pdu,
      for: MAPContextIdentifier(packet: packet),
      from: port,
      sourceMacAddress: packet.sourceMacAddress
    )
  }

  func rx(
    pdu: MRPDU,
    for contextIdentifier: MAPContextIdentifier,
    from port: P,
    sourceMacAddress: EUI48
  ) throws {
    let participant = try findParticipant(for: contextIdentifier, port: port)
    try participant.rx(pdu: pdu, sourceMacAddress: sourceMacAddress)
  }

  func flush(for contextIdentifier: MAPContextIdentifier) throws {
    try apply(for: contextIdentifier) { try $0.flush() }
  }

  func redeclare(for contextIdentifier: MAPContextIdentifier) throws {
    try apply(for: contextIdentifier) { try $0.redeclare() }
  }
}
