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

import Logging

public enum AdministrativeControl {
  case normalParticipant // the state machine participates normally in MRP exchanges
  case newOnlyParticipant // the state machine sends only New MRP messages
  case nonParticipant // the state machine does not send any MRP messages
}

public typealias AttributeSubtype = UInt8

public protocol Application<P>: AnyObject, Equatable, Hashable, Sendable {
  associatedtype P: Port

  typealias ApplyFunction<T> = (Participant<Self>) throws -> T
  typealias AsyncApplyFunction<T> = (Participant<Self>) async throws -> T

  var validAttributeTypes: ClosedRange<AttributeType> { get }
  var groupAddress: EUI48 { get }
  var etherType: UInt16 { get }
  var protocolVersion: ProtocolVersion { get }
  var hasAttributeListLength: Bool { get }

  var controller: MRPController<P>? { get }

  // notifications from controller when a port is added, didUpdated or removed
  // if contextIdentifier is MAPBaseSpanningTreeContext, the ports are physical
  // ports on the bridge; otherwise, they are virtual ports managed by MVRP.
  func didAdd(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) async throws
  func didUpdate(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws
  func didRemove(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws

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

  func hasAttributeSubtype(for: AttributeType) -> Bool
  func administrativeControl(for: AttributeType) throws -> AdministrativeControl
  var nonBaseContextsSupported: Bool { get }

  func makeNullValue(for attributeType: AttributeType) throws -> any Value
  func deserialize(
    attributeOfType attributeType: AttributeType,
    from deserializationContext: inout DeserializationContext
  ) throws -> any Value

  func joinIndicated<V: Value>(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: V,
    isNew: Bool,
    eventSource: ParticipantEventSource
  ) async throws

  func leaveIndicated<V: Value>(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: V,
    eventSource: ParticipantEventSource
  ) async throws
}

public extension Application {
  func hash(into hasher: inout Hasher) {
    etherType.hash(into: &hasher)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.etherType == rhs.etherType
  }
}

extension Application {
  typealias ParticipantSpecificApplyFunction<T> = (Participant<Self>) -> (T) throws -> ()
  typealias AsyncParticipantSpecificApplyFunction<T> = (Participant<Self>) -> (T) async throws -> ()

  func periodic(for contextIdentifier: MAPContextIdentifier? = nil) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await participant.tx()
    }
  }

  private func apply<T>(
    for contextIdentifier: MAPContextIdentifier,
    with arg: T,
    _ block: ParticipantSpecificApplyFunction<T>
  ) throws {
    try apply(for: contextIdentifier) { participant in
      try block(participant)(arg)
    }
  }

  private func apply<T>(
    for contextIdentifier: MAPContextIdentifier,
    with arg: T,
    _ block: AsyncParticipantSpecificApplyFunction<T>
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await block(participant)(arg)
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
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await participant.join(
        attributeType: attributeType,
        attributeSubtype: attributeSubtype,
        attributeValue: attributeValue,
        isNew: isNew
      )
    }
  }

  func leave(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype? = nil,
    attributeValue: some Value,
    for contextIdentifier: MAPContextIdentifier
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await participant.leave(
        attributeType: attributeType,
        attributeSubtype: attributeSubtype,
        attributeValue: attributeValue
      )
    }
  }

  func rx(packet: IEEE802Packet, from port: P) async throws {
    var deserializationContext = DeserializationContext(packet.payload)
    let pdu = try MRPDU(deserializationContext: &deserializationContext, application: self)
    try await rx(
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
  ) async throws {
    guard pdu.protocolVersion <= protocolVersion else { throw MRPError.badProtocolVersion }
    let participant = try findParticipant(for: contextIdentifier, port: port)
    for message in pdu.messages {
      try await participant.rx(message: message, sourceMacAddress: sourceMacAddress)
    }
  }

  func flush(for contextIdentifier: MAPContextIdentifier) async throws {
    try await apply(for: contextIdentifier) { try await $0.flush() }
  }

  func redeclare(for contextIdentifier: MAPContextIdentifier) async throws {
    try await apply(for: contextIdentifier) { try await $0.redeclare() }
  }
}

public protocol ApplicationEventHandler<A>: Application {
  associatedtype A: Application

  func preApplicantEventHandler(context: EventContext<A>) async throws
  func postApplicantEventHandler(context: EventContext<A>)
}
