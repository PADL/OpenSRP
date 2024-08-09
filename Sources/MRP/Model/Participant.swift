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

// one Participant per MRP application per Port
//
// a) Participants can issue declarations for MRP application attributes (10.2,
//    10.3, 10.7.3, and 10.7.7).
// b) Participants can withdraw declarations for attributes (10.2, 10.3,
//    10.7.3, and 10.7.7).
// c) Each Bridge propagates declarations to MRP Participants (10.3).
// d) MRP Participants can track the current state of declaration and
//    registration of attributes on each Port of the participant device (10.7.7 and
//    10.7.8).
// e) MRP Participants can remove state information relating to attributes that
//    are no longer active within part or all of the network, e.g., as a result of
//   the failure of a participant (10.7.8 and 10.7.9).
// ...
//
// For a given Port of an MRP-aware Bridge and MRP application supported by that
// Bridge, an instance of an MRP Participant can exist for each MRP Attribute
// Propagation Context (MAP Context) understood by the Bridge. A MAP Context
// identifies the set of Bridge Ports that form the applicable active topology
// (8.4).

import Logging

enum ParticipantType {
  case full
  case pointToPoint
  case newOnly
  case applicantOnly
}

public struct ParticipantEventFlags: OptionSet, Sendable {
  public typealias RawValue = UInt32

  public let rawValue: RawValue

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  // fired from a timer
  public static let firedFromTimer = ParticipantEventFlags(rawValue: 1 << 0)

  // source is local MAC address, e.g. from kernel MVRP stack, used to avoid loopback
  public static let sourceIsLocal = ParticipantEventFlags(rawValue: 1 << 1)

  // locally initiated from mvrpd
  public static let locallyInitiated = ParticipantEventFlags(rawValue: 1 << 2)
}

public final actor Participant<A: Application>: Equatable, Hashable {
  public static func == (lhs: Participant<A>, rhs: Participant<A>) -> Bool {
    lhs.application == rhs.application && lhs.port == rhs.port && lhs.contextIdentifier == rhs
      .contextIdentifier
  }

  public nonisolated func hash(into hasher: inout Hasher) {
    application?.hash(into: &hasher)
    port.hash(into: &hasher)
    contextIdentifier.hash(into: &hasher)
  }

  private enum EnqueuedEvent {
    struct AttributeEvent {
      let attributeEvent: MRP.AttributeEvent
      let attributeValue: _AttributeValueState<A>
    }

    case attributeEvent(AttributeEvent)
    case leaveAllEvent(AttributeType)

    var attributeType: AttributeType {
      switch self {
      case let .attributeEvent(attributeEvent):
        attributeEvent.attributeValue.attributeType
      case let .leaveAllEvent(attributeType):
        attributeType
      }
    }

    var isLeaveAll: Bool {
      switch self {
      case .attributeEvent:
        false
      case .leaveAllEvent:
        true
      }
    }

    var unsafeAttributeEvent: AttributeEvent {
      switch self {
      case let .attributeEvent(attributeEvent):
        attributeEvent
      case .leaveAllEvent:
        fatalError("attemped to unsafely unwrap LeaveAll event")
      }
    }
  }

  private typealias EnqueuedEvents = [AttributeType: [EnqueuedEvent]]

  private enum LeaveAllState {
    case Active
    case Passive

    mutating func handle(
      event: ProtocolEvent,
      flags _: StateMachineHandlerFlags = []
    ) -> [ProtocolAction] {
      let action: ProtocolAction

      switch event {
      case .Begin:
        action = .leavealltimer
        self = .Passive
      case .Flush:
        action = .leavealltimer
        self = .Passive
      case .tx:
        precondition(self == .Active)
        action = .sLA
        self = .Passive
      case .rLA:
        action = .leavealltimer
        self = .Passive
      case .leavealltimer:
        action = .leavealltimer
        self = .Active
      default:
        return []
      }

      return [action]
    }
  }

  private var _attributes = [AttributeType: Set<_AttributeValueState<A>>]()
  private var _enqueuedEvents = EnqueuedEvents()
  private var _leaveAllState = LeaveAllState.Passive
  private var _leaveAllTimer: Timer!
  private var _jointimer: Timer!
  private nonisolated let _mad: Weak<MAD<A.P>>
  private nonisolated let _application: Weak<A>

  fileprivate let _logger: Logger
  fileprivate let _type: ParticipantType
  fileprivate nonisolated var mad: MAD<A.P>? { _mad.object }
  fileprivate nonisolated var application: A? { _application.object }

  nonisolated let port: A.P
  nonisolated let contextIdentifier: MAPContextIdentifier

  init(
    mad: MAD<A.P>,
    application: A,
    port: A.P,
    contextIdentifier: MAPContextIdentifier,
    type: ParticipantType? = nil
  ) async {
    _mad = Weak(mad)
    _application = Weak(application)
    self.contextIdentifier = contextIdentifier

    self.port = port

    if let type {
      _type = type
    } else if port.isPointToPoint {
      _type = .pointToPoint
    } else {
      _type = .full
    }

    _logger = mad.logger

    // The Join Period Timer, jointimer, controls the interval between transmit
    // opportunities that are applied to the Applicant state machine. An
    // instance of this timer is required on a per-Port, per-MRP Participant
    // basis. The value of JoinTime used to initialize this timer is determined
    // in accordance with 10.7.11.
    _jointimer = Timer(onExpiry: _onJoinTimerExpired)
    _jointimer.start(interval: JoinTime)

    // The Leave All Period Timer, leavealltimer, controls the frequency with
    // which the LeaveAll state machine generates LeaveAll PDUs. The timer is
    // required on a per-Port, per-MRP Participant basis. If LeaveAllTime is
    // zero, the Leave All Period Timer is not started; otherwise, the Leave
    // All Period Timer is set to a random value, T, in the range LeaveAllTime
    // < T < 1.5 × LeaveAllTime when it is started. LeaveAllTime is defined in
    // Table 10-7.
    _leaveAllTimer = Timer(onExpiry: _onLeaveAllTimerExpired)
    let leaveAllTime = await mad.leaveAllTime
    if leaveAllTime != Duration.zero {
      _leaveAllTimer.start(interval: leaveAllTime)
    }
  }

  @Sendable
  private func _onJoinTimerExpired() async throws {
    // this will send a .tx/.txLA event to all attributes which will then make
    // the appropriate state transitions, potentially triggering the encoding
    // of a vector
    switch _leaveAllState {
    case .Active:
      try await _handleLeaveAll(
        event: .tx,
        flags: .firedFromTimer
      ) // sets LeaveAll to passive and emits sLA action
      try await _apply(event: .txLA, flags: .firedFromTimer)
    case .Passive:
      try await _apply(event: .tx, flags: .firedFromTimer)
    }
  }

  @Sendable
  private func _onLeaveAllTimerExpired() async throws {
    try await _handleLeaveAll(event: .leavealltimer, flags: .firedFromTimer)
  }

  private func _makeVector(
    for attributeType: AttributeType,
    attributeEvents: [EnqueuedEvent.AttributeEvent]
  ) throws -> [UInt8] {
    guard let application else { throw MRPError.internalError }

    return switch try application.packedEventsType(for: attributeType) {
    case .threePackedType:
      ThreePackedEvents.chunked(attributeEvents.map(\.attributeEvent.rawValue)).map(\.value)
    case .fourPackedType:
      FourPackedEvents.chunked(attributeEvents.map(\.attributeEvent.rawValue)).map(\.value)
    }
  }

  private func _coalesce(events: EnqueuedEvents) throws -> [Message] {
    guard let application else { throw MRPError.internalError }

    var messages = [Message]()

    for event in events {
      let leaveAll = event.value.contains(where: \.isLeaveAll)
      let attributeEvents = event.value.filter { !$0.isLeaveAll }.map(\.unsafeAttributeEvent)
        .sorted(by: {
          $0.attributeValue.index < $1.attributeValue.index
        })
      let valueIndexGroups = attributeEvents.map(\.attributeValue.index).consecutivelyGrouped
      let vector = try _makeVector(for: event.key, attributeEvents: attributeEvents)

      var vectorAttributes: [VectorAttribute<AnyValue>] = valueIndexGroups.map { group in
        let firstValue = attributeEvents
          .first(where: { $0.attributeValue.index == group[0] })!
          .attributeValue.value
        return VectorAttribute<AnyValue>(
          leaveAllEvent: leaveAll ? .LeaveAll : .NullLeaveAllEvent,
          numberOfValues: NumberOfValues(group.count),
          firstValue: firstValue,
          vector: vector
        )
      }

      if vectorAttributes.count == 0, leaveAll {
        let vectorAttribute = try VectorAttribute<AnyValue>(
          leaveAllEvent: .LeaveAll,
          numberOfValues: 0,
          firstValue: AnyValue(application.makeValue(for: event.key)),
          vector: [UInt8]()
        )
        vectorAttributes.append(vectorAttribute)
      }

      messages.append(Message(attributeType: event.key, attributeList: vectorAttributes))
    }

    _logger.trace("coalesced events \(events) into \(messages)")

    return messages
  }

  private func _txEnqueue(_ event: EnqueuedEvent) {
    _logger.trace("enqueing event \(event)")
    if let index = _enqueuedEvents.index(forKey: event.attributeType) {
      _enqueuedEvents.values[index].append(event)
    } else {
      _enqueuedEvents[event.attributeType] = [event]
    }
  }

  fileprivate func _txEnqueue(
    attributeEvent: AttributeEvent,
    attributeValue: _AttributeValueState<A>
  ) {
    let event = EnqueuedEvent.AttributeEvent(
      attributeEvent: attributeEvent,
      attributeValue: attributeValue
    )
    _txEnqueue(.attributeEvent(event))
  }

  private func _txEnqueueLeaveAllEvents() throws {
    guard let application else { throw MRPError.internalError }
    for attributeType in application.validAttributeTypes {
      _txEnqueue(.leaveAllEvent(attributeType))
    }
  }

  // handle an event in the LeaveAll state machine
  private func _handleLeaveAll(event: ProtocolEvent, flags: ParticipantEventFlags) async throws {
    let action = _leaveAllState.handle(event: event).first!

    switch action {
    case .leavealltimer:
      // For an instance of the LeaveAll state machine, the leavealltimer!
      // event is deemed to have occurred either when the leavealltimer associated
      // with that state machine expires or when a Flush! event (10.7.5.2)
      // occurs for the Port and spanning tree instance associated with that
      // state machine.
      break
    case .sLA:
      // a) The LeaveAll state machine associated with that instance of the
      // Applicant or Registrar state machine performs the sLA action
      // (10.7.6.6); or a MRPDU is received with a LeaveAll
      try await _apply(event: .rLA, flags: flags)
      try _txEnqueueLeaveAllEvents()
    default:
      fatalError("invalid LeaveAll state")
    }
  }

  private func _apply(event: ProtocolEvent, flags: ParticipantEventFlags) async throws {
    try await _apply { attribute in
      try await attribute.handle(event: event, flags: flags)
    }
  }

  fileprivate func _txDequeue() async throws -> MRPDU {
    guard let application = _application.object else { throw MRPError.internalError }
    let enqueuedMessages = try _coalesce(events: _enqueuedEvents)
    let pdu = MRPDU(
      protocolVersion: application.protocolVersion,
      messages: enqueuedMessages
    )

    _enqueuedEvents.removeAll()

    return pdu
  }

  fileprivate func _apply(
    attributeType: AttributeType? = nil,
    _ block: ParticipantApplyFunction<A>
  ) async rethrows {
    if let attributeType {
      guard let attributeValues = _attributes[attributeType] else { return }
      for attributeValue in attributeValues {
        try await block(attributeValue)
      }
    } else {
      for attribute in _attributes {
        for attributeValue in attribute.value {
          try await block(attributeValue)
        }
      }
    }
  }

  fileprivate func _handle(
    attributeEvent: AttributeEvent,
    with a: _AttributeValueState<A>,
    flags: ParticipantEventFlags
  ) async throws {
    let protocolEvent = attributeEvent.protocolEvent
    try await a.handle(event: protocolEvent, flags: flags)
  }

  // TODO: use a more efficient representation such as a bitmask
  private func _findAttributeValueState<V: Value>(
    attributeType: AttributeType,
    firstValue: V,
    index: Int,
    isNew: Bool
  ) throws -> _AttributeValueState<A> {
    let absoluteValue = try firstValue.makeValue(relativeTo: index)

    if let attributeValue = _attributes[attributeType]?.first(where: {
      ($0.value.value as? V) == absoluteValue
    }) {
      return attributeValue
    } else if isNew {
      let attributeValue = _AttributeValueState(
        participant: self,
        type: attributeType,
        value: absoluteValue
      )
      if let index = _attributes.index(forKey: attributeType) {
        _attributes.values[index].insert(attributeValue)
      } else {
        _attributes[attributeType] = [attributeValue]
      }
      return attributeValue
    } else {
      throw MRPError.unknownAttributeType
    }
  }

  private func _getAttributeEvents(
    attributeType: AttributeType,
    vectorAttribute: VectorAttribute<some Value>
  ) throws
    -> [AttributeEvent]
  {
    guard let application else { throw MRPError.internalError }
    switch try application.packedEventsType(for: attributeType) {
    case .threePackedType:
      return vectorAttribute.threePackedEvents.compactMap { AttributeEvent(rawValue: $0) }
    case .fourPackedType:
      return vectorAttribute.fourPackedEvents.compactMap { AttributeEvent(rawValue: $0) }
    }
  }

  func rx(message: Message, sourceMacAddress: EUI48) async throws {
    var flags = ParticipantEventFlags()
    if _isEqualMacAddress(sourceMacAddress, port.macAddress) {
      flags.insert(.sourceIsLocal)
    }
    for vectorAttribute in message.attributeList {
      let packedEvents = try _getAttributeEvents(
        attributeType: message.attributeType,
        vectorAttribute: vectorAttribute
      )
      guard packedEvents.count >= vectorAttribute.numberOfValues else {
        throw MRPError.badVectorAttribute
      }
      for i in 0..<Int(vectorAttribute.numberOfValues) {
        // TODO: what is the correct policy for unknown attributes
        guard let attribute = try? _findAttributeValueState(
          attributeType: message.attributeType,
          firstValue: vectorAttribute.firstValue,
          index: i,
          isNew: packedEvents[i] == .New
        ) else { continue }
        try await _handle(
          attributeEvent: packedEvents[i],
          with: attribute,
          flags: flags
        )
      }

      if vectorAttribute.leaveAllEvent == .LeaveAll {
        try await _handleLeaveAll(event: .rLA, flags: flags)
      }
    }
  }

  fileprivate func _getSmFlags(for attributeType: AttributeType) throws
    -> StateMachineHandlerFlags
  {
    guard let application else { throw MRPError.internalError }
    var flags: StateMachineHandlerFlags = []
    if _type == .pointToPoint { flags.insert(.operPointToPointMAC) }
    let administrativeControl = try application.administrativeControl(for: attributeType)
    switch administrativeControl {
    case .normalParticipant:
      break
    case .newOnlyParticipant:
      flags.insert(.registrationFixedNewPropagated)
    case .nonParticipant:
      flags.insert(.registrationFixedNewIgnored)
    }
    return flags
  }

  func tx() async throws {
    guard let application, let mad else { throw MRPError.internalError }
    try await mad.bridge.tx(
      pdu: _txDequeue(),
      for: application,
      contextIdentifier: contextIdentifier,
      on: port
    )
  }

  // A Flush! event signals to the Registrar state machine that there is a
  // need to rapidly deregister information on the Port associated with the
  // state machine as a result of a topology change that has occurred in the
  // network topology that supports the propagation of MRP information. If
  // the network topology is maintained by means of the spanning tree
  // protocol state machines, then, for the set of Registrar state machines
  // associated with a given Port and spanning tree instance, this event is
  // generated when the Port Role changes from either Root Port or Alternate
  // Port to Designated Port.
  func flush() async throws {
    try await _apply(event: .Flush, flags: .locallyInitiated)
    try await _handleLeaveAll(event: .Flush, flags: .locallyInitiated)
  }

  // A Re-declare! event signals to the Applicant and Registrar state machines
  // that there is a need to rapidly redeclare registered information on the
  // Port associated with the state machines as a result of a topology change
  // that has occurred in the network topology that supports the propagation
  // of MRP information. If the network topology is maintained by means of the
  // spanning tree protocol state machines, then, for the set of Applicant and
  // Registrar state machines associated with a given Port and spanning tree
  // instance, this event is generated when the Port Role changes from
  // Designated Port to either Root Port or Alternate Port.
  func redeclare() async throws {
    try await _apply(event: .ReDeclare, flags: .locallyInitiated)
  }

  func join(
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool
  ) async throws {
    let attribute = try _findAttributeValueState(
      attributeType: attributeType,
      firstValue: attributeValue,
      index: 0,
      isNew: isNew
    )
    try await _handle(
      attributeEvent: isNew ? .New : .JoinMt,
      with: attribute,
      flags: .locallyInitiated
    )
  }

  func leave(
    attributeType: AttributeType,
    attributeValue: some Value
  ) async throws {
    let attribute = try _findAttributeValueState(
      attributeType: attributeType,
      firstValue: attributeValue,
      index: 0,
      isNew: false
    )
    try await _handle(attributeEvent: .Lv, with: attribute, flags: .locallyInitiated)
  }
}

private typealias ParticipantApplyFunction<A: Application> =
  @Sendable (_AttributeValueState<A>) async throws -> ()

private final class _AttributeValueState<A: Application>: @unchecked Sendable, Hashable,
  Equatable
{
  typealias P = Participant<A>
  static func == (lhs: _AttributeValueState<A>, rhs: _AttributeValueState<A>) -> Bool {
    lhs.attributeType == rhs.attributeType && lhs.value == rhs.value
  }

  private let _participant: Weak<P>
  private let applicant = Applicant() // A per-Attribute Applicant state machine (10.7.7)
  private var registrar: Registrar? // A per-Attribute Registrar state machine (10.7.8)
  let attributeType: AttributeType
  let value: AnyValue
  var index: Int { value.index }

  var participant: P? { _participant.object }

  init(participant: P, type: AttributeType, value: any Value) {
    _participant = Weak(participant)
    attributeType = type
    self.value = AnyValue(value)
    if participant._type != .applicantOnly {
      registrar = Registrar(onLeaveTimerExpired: {
        try await self.handle(event: .leavetimer, flags: .firedFromTimer)
      })
    }
  }

  func hash(into hasher: inout Hasher) {
    attributeType.hash(into: &hasher)
    if let serialized = try? value.serialized() {
      serialized.hash(into: &hasher)
    }
  }

  func handle(event: ProtocolEvent, flags: ParticipantEventFlags) async throws {
    guard let participant else { throw MRPError.internalError }
    let smFlags = try await participant._getSmFlags(for: attributeType)

    participant._logger
      .trace(
        "handling protocol event \(event) flags \(smFlags) state A \(applicant) R \(registrar?.description ?? "-")"
      )

    let applicantAction = applicant.handle(event: event, flags: smFlags)
    if let applicantAction {
      participant._logger.trace("applicant action for event \(event): \(applicantAction)")
      try await handle(applicantAction: applicantAction, flags: flags)
    }

    if let registrarAction = registrar?.handle(event: event, flags: smFlags) {
      participant._logger.trace("registrar action for event \(event): \(registrarAction)")
      try await handle(registrarAction: registrarAction, flags: flags)
    }
  }

  func handle(applicantAction action: Applicant.Action, flags: ParticipantEventFlags) async throws {
    guard let participant else { throw MRPError.internalError }
    participant._logger.trace("handling applicant action \(action)")
    switch action {
    case .sN:
      // The AttributeEvent value New is encoded in the Vector as specified in
      // 10.7.6.1.
      await participant._txEnqueue(attributeEvent: .New, attributeValue: self)
    case .sJ:
      fallthrough
    case .sJ_:
      // The [sJ] variant indicates that the action is only necessary in cases
      // where transmitting the value, rather than terminating a vector and
      // starting a new one, makes for more optimal/ encoding; i.e.,
      // transmitting the value is not necessary for correct/ protocol
      // operation.
      guard let registrar else { break }
      if registrar.state == .IN {
        await participant._txEnqueue(attributeEvent: .JoinIn, attributeValue: self)
      } else if registrar.state == .MT || registrar.state == .LV {
        await participant._txEnqueue(attributeEvent: .JoinMt, attributeValue: self)
      }
    case .sL:
      fallthrough
    case .sL_:
      await participant._txEnqueue(attributeEvent: .Lv, attributeValue: self)
    case .s:
      fallthrough
    case .s_:
      guard let registrar else { break }
      if registrar.state == .IN {
        await participant._txEnqueue(attributeEvent: .In, attributeValue: self)
      } else if registrar.state == .MT || registrar.state == .LV {
        await participant._txEnqueue(attributeEvent: .Mt, attributeValue: self)
      }
    default:
      break
    }
  }

  func handle(registrarAction action: Registrar.Action, flags: ParticipantEventFlags) async throws {
    guard let participant else { throw MRPError.internalError }
    participant._logger.trace("handling registrar action \(action)")
    switch action {
    case .New:
      try await participant.application?.joinIndicated(
        contextIdentifier: participant.contextIdentifier,
        port: participant.port,
        attributeType: attributeType,
        attributeValue: value,
        isNew: true,
        flags: flags
      )
    case .Join:
      try await participant.application?.joinIndicated(
        contextIdentifier: participant.contextIdentifier,
        port: participant.port,
        attributeType: attributeType,
        attributeValue: value,
        isNew: false,
        flags: flags
      )
    case .Lv:
      try await participant.application?.leaveIndicated(
        contextIdentifier: participant.contextIdentifier,
        port: participant.port,
        attributeType: attributeType,
        attributeValue: value,
        flags: flags
      )
    case .leavetimer:
      break
    }
  }
}
