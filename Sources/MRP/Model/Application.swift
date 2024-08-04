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

enum AdministrativeControl {
  case normalParticipant // the state machine participates normally in MRP exchanges
  case newOnlyParticipant // the state machine sends only New MRP messages
  case nonParticipant // the state machine does not send any MRP messages
}

protocol Application<P>: AnyObject, Equatable, Hashable, Sendable {
  associatedtype P: Port

  typealias ApplyFunction<T> = (Participant<Self>) throws -> T
  typealias AsyncApplyFunction<T> = (Participant<Self>) async throws -> T

  // these are constant values defined by the application type
  var validAttributeTypes: ClosedRange<AttributeType> { get }
  var groupMacAddress: EUI48 { get }
  var etherType: UInt16 { get }
  var protocolVersion: ProtocolVersion { get }

  var mad: Controller<P>? { get }

  func register(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) async throws
  func update(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws
  func deregister(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws

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

  func makeValue(for attributeType: AttributeType, at index: Int) throws -> any Value
  func deserialize(
    attributeOfType attributeType: AttributeType,
    from deserializationContext: inout DeserializationContext
  ) throws -> any Value

  func packedEventsType(for: AttributeType) throws -> PackedEventsType
  func administrativeControl(for: AttributeType) throws -> AdministrativeControl

  func joinIndicated<V: Value>(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: V,
    isNew: Bool
  ) async throws

  func leaveIndicated<V: Value>(
    contextIdentifier: MAPContextIdentifier,
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

  var logger: Logger? {
    mad?.logger
  }
}

extension Application {
  typealias ParticipantSpecificApplyFunction<T> = (Participant<Self>) -> (T) throws -> ()
  typealias AsyncParticipantSpecificApplyFunction<T> = (Participant<Self>) -> (T) async throws -> ()

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
    let participant = try findParticipant(port: port)
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

protocol ApplicationDelegate<P>: Sendable {
  associatedtype P: Port

  func register(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws
  func update(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws
  func deregister(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws
}

protocol BaseApplication: Application where P == P {
  typealias MAPParticipantDictionary = [MAPContextIdentifier: Set<Participant<Self>>]

  var _mad: Weak<Controller<P>> { get }
  var _participants: ManagedCriticalState<MAPParticipantDictionary> { get }
  var _delegate: (any ApplicationDelegate<P>)? { get }
}

extension BaseApplication {
  var mad: Controller<P>? { _mad.object }

  func add(participant: Participant<Self>) throws {
    _participants.withCriticalRegion {
      if let index = $0.index(forKey: participant.contextIdentifier) {
        $0.values[index].insert(participant)
      } else {
        $0[participant.contextIdentifier] = Set([participant])
      }
    }
  }

  func remove(
    participant: Participant<Self>
  ) throws {
    _participants.withCriticalRegion {
      $0[participant.contextIdentifier]?.remove(participant)
    }
  }

  @discardableResult
  func apply<T>(
    for contextIdentifier: MAPContextIdentifier? = nil,
    _ block: AsyncApplyFunction<T>
  ) async rethrows -> [T] {
    var participants: Set<Participant<Self>>?
    _participants.withCriticalRegion {
      participants = $0[contextIdentifier ?? 0]
    }
    var ret = [T]()
    if let participants {
      for participant in participants {
        try await ret.append(block(participant))
      }
    }
    return ret
  }

  @discardableResult
  func apply<T>(
    for contextIdentifier: MAPContextIdentifier? = nil,
    _ block: ApplyFunction<T>
  ) rethrows -> [T] {
    var participants: Set<Participant<Self>>?
    _participants.withCriticalRegion {
      participants = $0[contextIdentifier ?? 0]
    }
    var ret = [T]()
    if let participants {
      for participant in participants {
        try ret.append(block(participant))
      }
    }
    return ret
  }

  func register(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) async throws {
    for port in context {
      guard (try? findParticipant(for: MAPBaseSpanningTreeContext, port: port)) == nil
      else {
        throw MRPError.portAlreadyExists
      }
      guard let mad else { throw MRPError.internalError }
      let participant = await Participant<Self>(
        controller: mad,
        application: self,
        port: port,
        contextIdentifier: contextIdentifier
      )
      try add(participant: participant)
    }
    try _delegate?.register(contextIdentifier: contextIdentifier, with: context)
  }

  func update(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws {
    for port in context {
      let participant = try findParticipant(
        for: MAPBaseSpanningTreeContext,
        port: port
      )
      Task { try await participant.redeclare() }
    }
    try _delegate?.update(contextIdentifier: contextIdentifier, with: context)
  }

  func deregister(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws {
    for port in context {
      let participant = try findParticipant(
        for: MAPBaseSpanningTreeContext,
        port: port
      )
      Task { try await participant.flush() }
      try remove(participant: participant)
    }
    try _delegate?.deregister(contextIdentifier: contextIdentifier, with: context)
  }

  func joinIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      try await participant.join(
        attributeType: attributeType,
        attributeValue: attributeValue,
        isNew: isNew
      )
    }
  }

  func leaveIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      try await participant.leave(
        attributeType: attributeType,
        attributeValue: attributeValue
      )
    }
  }
}
