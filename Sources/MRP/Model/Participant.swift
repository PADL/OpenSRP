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

import IEEE802
import Logging

enum ParticipantType {
  case full
  case pointToPoint
  case newOnly
  case applicantOnly
}

public struct EventContext<A: Application>: Sendable, CustomStringConvertible {
  let participant: Participant<A>
  let event: ProtocolEvent
  let eventSource: ParticipantEventSource
  let attributeType: AttributeType
  let attributeSubtype: AttributeSubtype?
  let attributeValue: any Value

  fileprivate let smFlags: StateMachineHandlerFlags
  fileprivate let applicant: Applicant
  fileprivate let registrar: Registrar?

  public var description: String {
    "EventContext(event: \(event), eventSource: \(eventSource), attributeType: \(attributeType), attributeSubtype: \(attributeSubtype ?? 0), attributeValue: \(attributeValue), smFlags: \(smFlags), state A \(applicant) R \(registrar?.description ?? "-"))"
  }
}

public enum AttributeValueFilter: Sendable {
  // match any value for this attribute type
  case matchAny
  // match any value whose index matches the provided index
  case matchAnyIndex(UInt64)
  // match any value whose index matches the provided value
  case matchIndex(any Value)
  // match value which matches exactly
  case matchEqual(any Value)
  case matchEqualWithSubtype((AttributeSubtype?, any Value))
  // match value which matches exactly, relative to provided index
  case matchRelative((any Value, UInt64))
  case matchRelativeWithSubtype((AttributeSubtype?, any Value, UInt64))

  fileprivate var _value: (any Value)? {
    get throws {
      switch self {
      case .matchAny:
        fallthrough
      case .matchAnyIndex:
        return nil
      case let .matchIndex(value):
        fallthrough
      case let .matchEqual(value):
        fallthrough
      case .matchEqualWithSubtype(let (_, value)):
        return value
      case .matchRelative(let (value, index)):
        fallthrough
      case .matchRelativeWithSubtype(let (_, value, index)):
        return try value.makeValue(relativeTo: index)
      }
    }
  }

  fileprivate var _subtype: AttributeSubtype? {
    switch self {
    case let .matchEqualWithSubtype((subtype, _)):
      fallthrough
    case let .matchRelativeWithSubtype((subtype, _, _)):
      return subtype
    default:
      return nil
    }
  }
}

public enum ParticipantEventSource: Sendable {
  // event source was an internal timer
  case timer
  // event source was the local port (e.g. kernel MVRP)
  case local
  // event source was a remote peer
  case peer
  // event source was explicit administrative control (e.g. TSN endpoint)
  case `internal`
  // event source was transitive via MAP function
  case map
  // event source was a preApplicantEventHandler/postApplicantEventHandler hook
  case application
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

  fileprivate enum EnqueuedEvent: Equatable {
    struct AttributeEvent: Equatable {
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

  private var _attributes = [AttributeType: Set<_AttributeValueState<A>>]()
  private var _enqueuedEvents = EnqueuedEvents()
  private var _leaveAll: LeaveAll!
  private var _jointimer: Timer!
  private nonisolated let _controller: Weak<MRPController<A.P>>
  private nonisolated let _application: Weak<A>

  fileprivate let _logger: Logger
  fileprivate let _type: ParticipantType
  fileprivate nonisolated var controller: MRPController<A.P>? { _controller.object }
  fileprivate nonisolated var application: A? { _application.object }

  nonisolated let port: A.P
  nonisolated let contextIdentifier: MAPContextIdentifier

  init(
    controller: MRPController<A.P>,
    application: A,
    port: A.P,
    contextIdentifier: MAPContextIdentifier,
    type: ParticipantType? = nil
  ) async {
    _controller = Weak(controller)
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

    _logger = controller.logger
    await _initTimers()
  }

  private func _initTimers() async {
    // The Join Period Timer, jointimer, controls the interval between transmit
    // opportunities that are applied to the Applicant state machine. An
    // instance of this timer is required on a per-Port, per-MRP Participant
    // basis. The value of JoinTime used to initialize this timer is determined
    // in accordance with 10.7.11.
    _jointimer = Timer(label: "jointimer", onExpiry: _onJoinTimerExpired)
    _jointimer.start(interval: JoinTime)

    // The Leave All Period Timer, leavealltimer, controls the frequency with
    // which the LeaveAll state machine generates LeaveAll PDUs. The timer is
    // required on a per-Port, per-MRP Participant basis. If LeaveAllTime is
    // zero, the Leave All Period Timer is not started; otherwise, the Leave
    // All Period Timer is set to a random value, T, in the range LeaveAllTime
    // < T < 1.5 × LeaveAllTime when it is started. LeaveAllTime is defined in
    // Table 10-7.
    _leaveAll = await LeaveAll(
      interval: controller!.leaveAllTime,
      onLeaveAllTimerExpired: _onLeaveAllTimerExpired
    )
  }

  deinit {
    _jointimer.stop()
    _leaveAll.stopLeaveAllTimer()
  }

  @Sendable
  private func _onJoinTimerExpired() async throws {
    // this will send a .tx/.txLA event to all attributes which will then make
    // the appropriate state transitions, potentially triggering the encoding
    // of a vector
    switch _leaveAll.state {
    case .Active:
      try await _handleLeaveAll(
        event: .tx,
        eventSource: .timer
      ) // sets LeaveAll to passive and emits sLA action
      try await _apply(event: .txLA, eventSource: .timer)
    case .Passive:
      try await _apply(event: .tx, eventSource: .timer)
    }
  }

  @Sendable
  private func _onLeaveAllTimerExpired() async throws {
    try await _handleLeaveAll(event: .leavealltimer, eventSource: .timer)
  }

  private func _apply(
    attributeType: AttributeType? = nil,
    matching filter: AttributeValueFilter? = nil,
    _ block: AsyncParticipantApplyFunction<A>
  ) async rethrows {
    for attribute in _attributes {
      for attributeValue in attribute.value {
        if let filter,
           !attributeValue.matches(attributeType: attributeType, matching: filter) { continue }
        try await block(attributeValue)
      }
    }
  }

  private func _apply(
    event: ProtocolEvent,
    eventSource: ParticipantEventSource
  ) async throws {
    try await _apply { attributeValue in
      try await attributeValue.handle(
        event: event,
        eventSource: eventSource
      )
    }
  }

  private func _findAttributeValueState(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter,
    createIfMissing: Bool = true
  ) throws -> _AttributeValueState<A> {
    if let attributeValue = _attributes[attributeType]?
      .first(where: { $0.matches(attributeType: attributeType, matching: filter) })
    {
      return attributeValue
    }

    guard createIfMissing else {
      throw MRPError.invalidAttributeValue
    }

    let filterValue = try filter._value!
    let attributeValue = _AttributeValueState(
      participant: self,
      type: attributeType,
      subtype: filter._subtype,
      value: filterValue
    )
    if let index = _attributes.index(forKey: attributeType) {
      _attributes.values[index].insert(attributeValue)
    } else {
      _attributes[attributeType] = [attributeValue]
    }
    return attributeValue
  }

  public func findAttribute(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter
  ) -> (AttributeSubtype?, any Value)? {
    let attributeValueState = try? _findAttributeValueState(
      attributeType: attributeType,
      matching: filter,
      createIfMissing: false
    )
    guard let attributeValueState, attributeValueState.registrarState == .IN else { return nil }
    return (attributeValueState.attributeSubtype, attributeValueState.unwrappedValue)
  }

  public func findAttributes(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter
  ) -> [(AttributeSubtype?, any Value)] {
    var attributeValues = [(AttributeSubtype?, any Value)]()

    for attributeValueState in _attributes[attributeType] ?? [] {
      guard attributeValueState.matches(attributeType: attributeType, matching: filter) else {
        continue
      }
      attributeValues.append((
        attributeValueState.attributeSubtype,
        attributeValueState.unwrappedValue
      ))
    }

    return attributeValues
  }

  fileprivate func _removeAttributeValueState(_ attributeValueState: _AttributeValueState<A>) {
    // TODO: debugging
    guard let index = _attributes.index(forKey: attributeValueState.attributeType) else {
      return
    }
    _attributes.values[index].remove(attributeValueState)
  }

  public func leaveNow(
    _ isIncluded: @Sendable (AttributeType, AttributeSubtype?, any Value)
      -> Bool
  ) async throws {
    await _apply { attributeValueState in
      guard isIncluded(
        attributeValueState.attributeType,
        attributeValueState.attributeSubtype,
        attributeValueState.unwrappedValue
      ) else {
        return
      }

      await _removeAttributeValueState(attributeValueState)
    }
  }

  private func _packMessages(with events: EnqueuedEvents) throws -> [Message] {
    guard let application else { throw MRPError.internalError }

    var messages = [Message]()

    for (attributeType, eventValue) in events {
      let leaveAll = eventValue.contains(where: \.isLeaveAll)
      let attributeEvents = eventValue.filter { !$0.isLeaveAll }.map(\.unsafeAttributeEvent)
        .sorted(by: {
          $0.attributeValue.index < $1.attributeValue.index
        })
      let attributeEventChunks: [[EnqueuedEvent.AttributeEvent]] = attributeEvents
        .reduce(into: []) {
          try? $0.last?.last?.attributeValue.advanced(by: 1) == $1.attributeValue ?
            $0[$0.index(before: $0.endIndex)].append($1) : $0.append([$1])
        }

      var vectorAttributes: [VectorAttribute<AnyValue>] = attributeEventChunks
        .map { attributeEventChunk in
          let attributeSubtypes: [AttributeSubtype]? = if application
            .hasAttributeSubtype(for: attributeType)
          {
            Array(attributeEventChunk.map { $0.attributeValue.attributeSubtype! })
          } else {
            nil
          }

          return VectorAttribute<AnyValue>(
            leaveAllEvent: leaveAll ? .LeaveAll : .NullLeaveAllEvent,
            firstValue: attributeEventChunk.first!.attributeValue.value,
            attributeEvents: Array(attributeEventChunk.map(\.attributeEvent)),
            applicationEvents: attributeSubtypes
          )
        }

      if vectorAttributes.count == 0, leaveAll {
        let vectorAttribute = try VectorAttribute<AnyValue>(
          leaveAllEvent: .LeaveAll,
          firstValue: AnyValue(application.makeNullValue(for: attributeType)),
          attributeEvents: [],
          applicationEvents: nil
        )
        vectorAttributes.append(vectorAttribute)
      }

      messages.append(Message(attributeType: attributeType, attributeList: vectorAttributes))
    }

    _logger.trace("packed events \(events) into \(messages)")

    return messages
  }

  private func _txEnqueue(_ event: EnqueuedEvent) {
    _logger.trace("enqueing event \(event)")
    if let index = _enqueuedEvents.index(forKey: event.attributeType) {
      if let eventIndex = _enqueuedEvents.values[index].firstIndex(where: { $0 == event }) {
        _enqueuedEvents.values[index][eventIndex] = event
      } else {
        _enqueuedEvents.values[index].append(event)
      }
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

  // handle an event in the LeaveAll state machine (10.5)
  private func _handleLeaveAll(
    event: ProtocolEvent,
    eventSource: ParticipantEventSource
  ) async throws {
    let action = _leaveAll.action(for: event)

    if action == .leavealltimer {
      _leaveAll.startLeaveAllTimer()
    } else if action == .sLA {
      // a) The LeaveAll state machine associated with that instance of the
      // Applicant or Registrar state machine performs the sLA action
      // (10.7.6.6); or a MRPDU is received with a LeaveAll
      try await _apply(event: .rLA, eventSource: eventSource)
      try _txEnqueueLeaveAllEvents()
    }
  }

  private func _txDequeue() async throws -> MRPDU? {
    guard let application else { throw MRPError.internalError }
    let enqueuedMessages = try _packMessages(with: _enqueuedEvents)
    if enqueuedMessages.isEmpty { return nil }

    let pdu = MRPDU(
      protocolVersion: application.protocolVersion,
      messages: enqueuedMessages
    )

    _enqueuedEvents.removeAll()

    return pdu
  }

  private func _handle(
    attributeEvent: AttributeEvent,
    with attributeValue: _AttributeValueState<A>,
    eventSource: ParticipantEventSource
  ) async throws {
    let protocolEvent = attributeEvent.protocolEvent
    try await attributeValue.handle(
      event: protocolEvent,
      eventSource: eventSource
    )
  }

  func rx(message: Message, sourceMacAddress: EUI48) async throws {
    let eventSource: ParticipantEventSource = _isEqualMacAddress(
      sourceMacAddress,
      port.macAddress
    ) ? .local : .peer
    for vectorAttribute in message.attributeList {
      let packedEvents = try vectorAttribute.attributeEvents
      guard packedEvents.count >= vectorAttribute.numberOfValues else {
        throw MRPError.badVectorAttribute
      }
      for i in 0..<Int(vectorAttribute.numberOfValues) {
        guard let attribute = try? _findAttributeValueState(
          attributeType: message.attributeType,
          matching: .matchRelativeWithSubtype((
            vectorAttribute.applicationEvents?[i],
            vectorAttribute.firstValue.value,
            UInt64(i)
          ))
        ) else { continue }
        try await _handle(
          attributeEvent: packedEvents[i],
          with: attribute,
          eventSource: eventSource
        )
      }

      if vectorAttribute.leaveAllEvent == .LeaveAll {
        try await _handleLeaveAll(event: .rLA, eventSource: eventSource)
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
    guard let application, let controller else { throw MRPError.internalError }
    guard let pdu = try await _txDequeue() else { return }
    _logger.debug("sending PDU \(pdu) port \(port.name) application \(type(of: application))")
    try await controller.bridge.tx(
      pdu: pdu,
      for: application,
      contextIdentifier: contextIdentifier,
      on: port,
      controller: controller
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
    try await _apply(event: .Flush, eventSource: .internal)
    try await _handleLeaveAll(event: .Flush, eventSource: .internal)
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
    try await _apply(event: .ReDeclare, eventSource: .internal)
  }

  func join(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype? = nil,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: ParticipantEventSource = .internal
  ) async throws {
    let attribute = try _findAttributeValueState(
      attributeType: attributeType,
      matching: .matchEqualWithSubtype((attributeSubtype, attributeValue))
    )
    try await _handle(
      attributeEvent: isNew ? .New : .JoinMt,
      with: attribute,
      eventSource: eventSource
    )
  }

  func leave(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype? = nil,
    attributeValue: some Value,
    eventSource: ParticipantEventSource = .internal
  ) async throws {
    let attribute = try _findAttributeValueState(
      attributeType: attributeType,
      matching: .matchEqualWithSubtype((attributeSubtype, attributeValue))
    )
    try await _handle(
      attributeEvent: .Lv,
      with: attribute,
      eventSource: eventSource
    )
  }
}

private typealias AsyncParticipantApplyFunction<A: Application> =
  @Sendable (_AttributeValueState<A>) async throws -> ()

private typealias ParticipantApplyFunction<A: Application> =
  @Sendable (_AttributeValueState<A>) throws -> ()

private final class _AttributeValueState<A: Application>: @unchecked
Sendable, Hashable, Equatable, CustomStringConvertible {
  typealias P = Participant<A>
  static func == (lhs: _AttributeValueState<A>, rhs: _AttributeValueState<A>) -> Bool {
    lhs.attributeType == rhs.attributeType &&
      lhs.attributeSubtype == rhs.attributeSubtype &&
      lhs.value == rhs.value
  }

  private let _participant: Weak<P>
  private let applicant = Applicant() // A per-Attribute Applicant state machine (10.7.7)
  private var registrar: Registrar? // A per-Attribute Registrar state machine (10.7.8)
  let attributeType: AttributeType
  let attributeSubtype: AttributeSubtype?
  let value: AnyValue
  var index: UInt64 { value.index }

  var participant: P? { _participant.object }
  var unwrappedValue: any Value { value.value }

  var registrarState: Registrar.State? {
    registrar?.state
  }

  var description: String {
    "\(type(of: self))(attributeType: \(attributeType), attributeSubtype: \(attributeSubtype ?? 0), attributeValue: \(value), A \(applicant) R \(registrar?.description ?? "-"))"
  }

  private init(
    participant: Weak<P>,
    type: AttributeType,
    subtype: AttributeSubtype?,
    value: AnyValue
  ) {
    precondition(!(value.value is AnyValue))
    _participant = participant
    registrar = nil
    attributeType = type
    attributeSubtype = subtype
    self.value = value
  }

  init(participant: P, type: AttributeType, subtype: AttributeSubtype?, value: some Value) {
    precondition(!(value is AnyValue))
    _participant = Weak(participant)
    attributeType = type
    attributeSubtype = subtype
    self.value = AnyValue(value)
    if participant._type != .applicantOnly {
      registrar = Registrar(onLeaveTimerExpired: onLeaveTimerExpired)
    }
  }

  deinit {
    registrar?.stopLeaveTimer()
  }

  @Sendable
  private func onLeaveTimerExpired() async throws {
    try await handle(
      event: .leavetimer,
      eventSource: .timer
    )
  }

  func hash(into hasher: inout Hasher) {
    attributeType.hash(into: &hasher)
    if let serialized = try? value.serialized() {
      serialized.hash(into: &hasher)
    }
  }

  func matches(
    attributeType filterAttributeType: AttributeType?,
    matching filter: AttributeValueFilter
  ) -> Bool {
    do {
      if let filterAttributeType {
        guard attributeType == filterAttributeType else { return false }
      }
      if let filterSubtype = filter._subtype {
        guard attributeSubtype == filterSubtype else { return false }
      }

      if let filterValue = try filter._value {
        guard value == AnyValue(filterValue) else { return false }
      } else if case let .matchAnyIndex(filterIndex) = filter {
        guard value.index == filterIndex else { return false }
      }

      return true
    } catch {
      return false
    }
  }

  func advanced(by offset: Int) throws -> Self {
    try Self(
      participant: _participant,
      type: attributeType,
      subtype: attributeSubtype,
      value: value.makeValue(relativeTo: UInt64(offset))
    )
  }

  func handle(
    event: ProtocolEvent,
    eventSource: ParticipantEventSource
  ) async throws {
    guard let participant else { throw MRPError.internalError }

    let context = try await EventContext(
      participant: participant,
      event: event,
      eventSource: eventSource,
      attributeType: attributeType,
      attributeSubtype: attributeSubtype,
      attributeValue: unwrappedValue,
      smFlags: participant._getSmFlags(for: attributeType),
      applicant: applicant,
      registrar: registrar
    )

    precondition(!(unwrappedValue is AnyValue))
    participant._logger.trace("handling \(context)")
    try await _handleApplicant(context: context) // attribute subtype can be adjusted by hook
    try await _handleRegistrar(context: context)
  }

  private func _handleApplicant(context: EventContext<A>) async throws {
    let applicantAction = applicant.action(for: context.event, flags: context.smFlags)

    if let applicantAction {
      context.participant._logger
        .trace("applicant action for event \(context.event): \(applicantAction)")
      let applicationEventHandler = context.participant
        .application as? any ApplicationEventHandler<A>
      try await applicationEventHandler?.preApplicantEventHandler(context: context)
      try await _handle(applicantAction: applicantAction, context: context)
      applicationEventHandler?.postApplicantEventHandler(context: context)
    }
  }

  private func _handle(
    applicantAction action: Applicant.Action,
    context: EventContext<A>
  ) async throws {
    var attributeEvent: AttributeEvent?

    switch action {
    case .sN:
      // The AttributeEvent value New is encoded in the Vector as specified in
      // 10.7.6.1.
      attributeEvent = .New
    case .sJ:
      fallthrough
    case .sJ_:
      // The [sJ] variant indicates that the action is only necessary in cases
      // where transmitting the value, rather than terminating a vector and
      // starting a new one, makes for more optimal/ encoding; i.e.,
      // transmitting the value is not necessary for correct/ protocol
      // operation.
      guard let registrar else { break }
      attributeEvent = (registrar.state == .IN) ? .JoinIn : .JoinMt
    case .sL:
      fallthrough
    case .sL_:
      attributeEvent = .Lv
    case .s:
      fallthrough
    case .s_:
      guard let registrar else { break }
      attributeEvent = (registrar.state == .IN) ? .In : .Mt
    }

    if let attributeEvent {
      await context.participant._txEnqueue(
        attributeEvent: attributeEvent,
        attributeValue: self
      )
    }
  }

  private func _handleRegistrar(context: EventContext<A>) async throws {
    if let registrarAction = context.registrar?.action(for: context.event, flags: context.smFlags) {
      context.participant._logger
        .trace("registrar action for event \(context.event): \(registrarAction)")
      try await _handle(
        registrarAction: registrarAction,
        context: context
      )

      if context.registrar?.state == .MT {
        await context.participant._removeAttributeValueState(self)
      }
    }
  }

  private func _handle(
    registrarAction action: Registrar.Action,
    context: EventContext<A>
  ) async throws {
    guard let application = context.participant.application else { throw MRPError.internalError }
    switch action {
    case .New:
      try await application.joinIndicated(
        contextIdentifier: context.participant.contextIdentifier,
        port: context.participant.port,
        attributeType: context.attributeType,
        attributeSubtype: context.attributeSubtype,
        attributeValue: context.attributeValue,
        isNew: true,
        eventSource: context.eventSource
      )
    case .Join:
      try await application.joinIndicated(
        contextIdentifier: context.participant.contextIdentifier,
        port: context.participant.port,
        attributeType: context.attributeType,
        attributeSubtype: context.attributeSubtype,
        attributeValue: context.attributeValue,
        isNew: false,
        eventSource: context.eventSource
      )
    case .Lv:
      try await application.leaveIndicated(
        contextIdentifier: context.participant.contextIdentifier,
        port: context.participant.port,
        attributeType: context.attributeType,
        attributeSubtype: context.attributeSubtype,
        attributeValue: context.attributeValue,
        eventSource: context.eventSource
      )
    }
  }
}
