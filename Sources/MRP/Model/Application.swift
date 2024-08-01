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

enum AdministrativeControl {
  case normalParticipant // the state machine participates normally in MRP exchanges
  case newOnlyParticipant // the state machine sends only New MRP messages
  case nonParticipant // the state machine does not send any MRP messages
}

protocol Application<P>: AnyObject, Equatable, Hashable, Sendable {
  associatedtype P: Port

  typealias ApplyFunction<T> = (Participant<Self>) async throws -> T

  // these are constant values defined by the application type
  var validAttributeTypes: ClosedRange<AttributeType> { get }
  var groupMacAddress: EUI48 { get }
  var etherType: UInt16 { get }
  var protocolVersion: ProtocolVersion { get }

  var mad: Controller<P>? { get }

  func add(context: MAPContext<P>, for contextidentifier: MAPContextIdentifier) throws
  func context(for contextIdentifier: MAPContextIdentifier) async throws -> MAPContext<P>

  func add(participant: Participant<Self>, for contextIdentifier: MAPContextIdentifier) throws
  func remove(participant: Participant<Self>, for contextIdentifier: MAPContextIdentifier) throws

  func onPortObservation(_: PortObservation<P>) async throws

  @discardableResult
  func apply<T>(
    for contextIdentifier: MAPContextIdentifier?,
    _ block: ApplyFunction<T>
  ) async rethrows -> [T]

  func makeValue(for attributeType: AttributeType, at index: Int) throws -> any Value
  func deserialize(
    attributeOfType attributeType: AttributeType,
    from deserializationContext: inout DeserializationContext
  ) throws -> any Value

  func packedEventsType(for: AttributeType) throws -> PackedEventsType
  func administrativeControl(for: AttributeType) throws -> AdministrativeControl

  func joinIndicated<V: Value>(
    port: P,
    attributeType: AttributeType,
    attributeValue: V,
    isNew: Bool
  ) async throws

  func leaveIndicated<V: Value>(
    port: P,
    attributeType: AttributeType,
    attributeValue: V
  ) async throws
}

extension Application {
  func hash(into hasher: inout Hasher) {
    etherType.hash(into: &hasher)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.etherType == rhs.etherType
  }
}

extension Application {
  typealias ParticipantSpecificApplyFunction<T> = (Participant<Self>) -> (T) async throws -> ()

  func periodic(
    for contextIdentifier: MAPContextIdentifier =
      MAPBaseSpanningTreeContext
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await participant.tx()
    }
  }

  func makeValue(for attributeType: AttributeType) throws -> any Value {
    try makeValue(for: attributeType, at: 0)
  }

  private func apply<T>(
    for contextIdentifier: MAPContextIdentifier,
    with arg: T,
    _ block: ParticipantSpecificApplyFunction<T>
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await block(participant)(arg)
    }
  }

  func findParticipants(for contextIdentifier: MAPContextIdentifier? = nil) async
    -> [Participant<Self>]
  {
    await apply(for: contextIdentifier) { $0 }
  }

  func findParticipant(
    for contextIdentifier: MAPContextIdentifier? = nil,
    port: P
  ) async throws -> Participant<Self> {
    guard let participant = await findParticipants(for: contextIdentifier)
      .first(where: { $0.port == port })
    else {
      throw MRPError.participantNotFound
    }
    return participant
  }

  func join(
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool,
    for contextIdentifier: MAPContextIdentifier
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await participant.join(
        attributeType: attributeType,
        attributeValue: attributeValue,
        isNew: isNew
      )
    }
  }

  func leave(
    attributeType: AttributeType,
    attributeValue: some Value,
    for contextIdentifier: MAPContextIdentifier
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      try await participant.leave(
        attributeType: attributeType,
        attributeValue: attributeValue
      )
    }
  }

  func rx(packet: IEEE802Packet, from port: P) async throws {
    var deserializationContext = DeserializationContext(packet.data)
    let pdu = try MRPDU(deserializationContext: &deserializationContext, application: self)
    try await rx(pdu: pdu, from: port)
  }

  func rx(pdu: MRPDU, from port: P) async throws {
    guard pdu.protocolVersion <= protocolVersion else { throw MRPError.badProtocolVersion }
    let participant = try await findParticipant(port: port)
    for message in pdu.messages {
      try await participant.rx(message: message)
    }
  }
}

extension Application {
  func flush(for contextIdentifier: MAPContextIdentifier) async throws {
    try await apply(for: contextIdentifier) { try await $0.flush() }
  }

  func redeclare(for contextIdentifier: MAPContextIdentifier) async throws {
    try await apply(for: contextIdentifier) { try await $0.redeclare() }
  }
}

protocol BaseApplication: Application where P == P {
  var _mad: Weak<Controller<P>> { get }
  var _participants: ManagedCriticalState<[Participant<Self>]> { get }

  func onPortObservationDelegate(_: PortObservation<P>)
}

extension BaseApplication {
  var mad: Controller<P>? { _mad.object }

  func add(context _: MAPContext<P>, for _: MAPContextIdentifier) throws {
    throw MRPError.invalidContextIdentifier
  }

  func context(for contextIdentifier: MAPContextIdentifier) async throws -> MAPContext<P> {
    guard contextIdentifier == MAPBaseSpanningTreeContext
    else { throw MRPError.invalidContextIdentifier }
    guard let mad else { throw MRPError.internalError }
    return await mad.ports
  }

  func add(participant: Participant<Self>, for contextIdentifier: MAPContextIdentifier) throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext
    else { throw MRPError.invalidContextIdentifier }
    _participants.withCriticalRegion {
      $0.append(participant)
    }
  }

  func remove(
    participant: Participant<Self>,
    for contextIdentifier: MAPContextIdentifier
  ) throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext
    else { throw MRPError.invalidContextIdentifier }
    try _participants.withCriticalRegion {
      guard let index = $0.firstIndex(where: {
        $0 == participant
      }) else { throw MRPError.invalidParticipantIdentifier }
      $0.remove(at: index)
    }
  }

  @discardableResult
  func apply<T>(
    for _: MAPContextIdentifier? = nil,
    _ block: ApplyFunction<T>
  ) async rethrows -> [T] {
    let participants = _participants.criticalState // snapshot
    var ret = [T]()
    for participant in participants {
      try await ret.append(block(participant))
    }
    return ret
  }

  func onPortObservation(_ observation: PortObservation<P>) async throws {
    switch observation {
    case let .added(port):
      guard await (try? findParticipant(for: MAPBaseSpanningTreeContext, port: port)) == nil
      else {
        throw MRPError.portAlreadyExists
      }
      guard let mad else { throw MRPError.internalError }
      let participant = await Participant<Self>(
        controller: mad,
        application: self,
        port: port
      )
      try add(participant: participant, for: MAPBaseSpanningTreeContext)
    case let .removed(port):
      let participant = try await findParticipant(
        for: MAPBaseSpanningTreeContext,
        port: port
      )
      try await participant.flush()
      try remove(participant: participant, for: MAPBaseSpanningTreeContext)
    case let .changed(port):
      let participant = try await findParticipant(
        for: MAPBaseSpanningTreeContext,
        port: port
      )
      try await participant.redeclare()
    }
    onPortObservationDelegate(observation)
  }

  func joinIndicated(
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool
  ) async throws {
    try await apply(for: MAPBaseSpanningTreeContext) { participant in
      guard participant.port != port else { return }
      try await participant.join(
        attributeType: attributeType,
        attributeValue: attributeValue,
        isNew: isNew
      )
    }
  }

  func leaveIndicated(
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value
  ) async throws {
    try await apply(for: MAPBaseSpanningTreeContext) { participant in
      guard participant.port != port else { return }
      try await participant.leave(
        attributeType: attributeType,
        attributeValue: attributeValue
      )
    }
  }
}
