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
import Synchronization

enum ParticipantType {
  case full
  case pointToPoint
  case newOnly
  case applicantOnly
}

private enum EnqueuedEvent<A: Application>: Equatable, CustomStringConvertible {
  struct AttributeEvent: Equatable, CustomStringConvertible {
    let attributeEvent: MRP.AttributeEvent
    let attributeValue: _AttributeValue<A>
    let encodingOptional: Bool

    var description: String {
      "attributeEvent: \(attributeEvent), attributeValue: \(attributeValue), encodingOptional: \(encodingOptional)"
    }
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

  var attributeEvent: AttributeEvent? {
    switch self {
    case let .attributeEvent(attributeEvent):
      attributeEvent
    case .leaveAllEvent:
      nil
    }
  }

  var unsafeAttributeEvent: AttributeEvent {
    attributeEvent!
  }

  var description: String {
    if isLeaveAll {
      "EnqueuedEvent(LA, attributeType: \(attributeType))"
    } else {
      "EnqueuedEvent(\(unsafeAttributeEvent))"
    }
  }
}

public final class Participant<A: Application>: Equatable, Hashable, CustomStringConvertible,
  @unchecked Sendable
{
  public static func == (lhs: Participant<A>, rhs: Participant<A>) -> Bool {
    lhs.application == rhs.application && lhs.port == rhs.port && lhs.contextIdentifier == rhs
      .contextIdentifier
  }

  public nonisolated func hash(into hasher: inout Hasher) {
    application?.hash(into: &hasher)
    port.hash(into: &hasher)
    contextIdentifier.hash(into: &hasher)
  }

  private typealias EnqueuedEvents = [AttributeType: [EnqueuedEvent<A>]]

  private var _attributes = [AttributeType: Set<_AttributeValue<A>>]()
  private var _enqueuedEvents = EnqueuedEvents()
  private nonisolated(unsafe) var _leaveAll: LeaveAll!
  private nonisolated(unsafe) var _jointimer: Timer!
  private var _rxInProgress = false
  private var _transmissionOpportunityTimestamps: [ContinuousClock.Instant] = []

  private nonisolated let _controller: Weak<MRPController<A.P>>
  private nonisolated let _application: Weak<A>

  fileprivate let _logger: Logger
  fileprivate let _type: ParticipantType
  fileprivate nonisolated var controller: MRPController<A.P>? { _controller.object }

  nonisolated var application: A? { _application.object }
  nonisolated let port: A.P
  nonisolated let contextIdentifier: MAPContextIdentifier

  init(
    controller: MRPController<A.P>,
    application: A,
    port: A.P,
    contextIdentifier: MAPContextIdentifier,
    type: ParticipantType? = nil
  ) {
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
    _initTimers()
    _logger.trace("\(self): initialized participant type \(_type)")
  }

  private func _assertIsolatedToApplication() {
    application?.assertIsolated("MRP Participant must be called from Application isolation")
  }

  public nonisolated var description: String {
    "\(application!.name)@\(port.name)"
  }

  private func _initTimers() {
    // The Join Period Timer, jointimer, controls the interval between transmit
    // opportunities that are applied to the Applicant state machine. An
    // instance of this timer is required on a per-Port, per-MRP Participant
    // basis. The value of JoinTime used to initialize this timer is determined
    // in accordance with 10.7.11.
    _jointimer = Timer(label: "jointimer") { @Sendable [self] in
      guard let application else { return }
      try await _onTxOpportunity(isolation: application)
    }

    // The Leave All Period Timer, leavealltimer, controls the frequency with
    // which the LeaveAll state machine generates LeaveAll PDUs. The timer is
    // required on a per-Port, per-MRP Participant basis. If LeaveAllTime is
    // zero, the Leave All Period Timer is not started; otherwise, the Leave
    // All Period Timer is set to a random value, T, in the range LeaveAllTime
    // < T < 1.5 × LeaveAllTime when it is started. LeaveAllTime is defined in
    // Table 10-7.
    _leaveAll = LeaveAll(interval: controller!.timerConfiguration
      .leaveAllTime)
    { @Sendable [self] in
      guard let application else { return }
      try await _onLeaveAllTimerExpired(isolation: application)
    }
  }

  deinit {
    _jointimer?.stop()
    _leaveAll?.stopLeaveAllTimer()
  }

  private func _onLeaveAllTimerExpired(isolation: isolated A) throws {
    try _handleLeaveAll(protocolEvent: .leavealltimer, eventSource: .leaveAllTimer)
  }

  private func _apply(
    attributeType: AttributeType? = nil,
    matching filter: AttributeValueFilter = .matchAny,
    _ block: ParticipantApplyFunction<A>
  ) rethrows {
    _assertIsolatedToApplication()

    for attribute in _attributes {
      for attributeValue in attribute.value {
        if !attributeValue.matches(attributeType: attributeType, matching: filter) { continue }
        try block(attributeValue)
      }
    }
  }

  private func _apply(
    attributeType: AttributeType? = nil,
    protocolEvent event: ProtocolEvent,
    eventSource: EventSource
  ) throws {
    _logger.trace("\(self): apply protocolEvent \(event), eventSource: \(eventSource)")
    try _apply(attributeType: attributeType) { attributeValue in
      try _handleAttributeValue(
        attributeValue,
        protocolEvent: event,
        eventSource: eventSource
      )
    }
  }

  private func _tx() async throws -> Bool {
    guard let application, let controller else { throw MRPError.internalError }
    guard let pdu = try _txDequeue() else { return false }
    _debugLogPdu(pdu, direction: .tx)
    try await controller.bridge.tx(
      pdu: pdu,
      for: application,
      contextIdentifier: contextIdentifier,
      on: port,
      controller: controller
    )
    return true
  }

  // If operPointToPointMAC is TRUE, a request for a transmit opportunity should
  // result in such an opportunity as soon as is practicable, given other system
  // constraints, and shall occur within the value specified for JoinTime subject
  // to not more than three such transmission opportunities occurring in any period
  // of 1.5 × JoinTime.
  //
  // If operPointToPointMAC is FALSE, and there is no pending request, a transmit
  // opportunity shall occur at a time value randomized between 0 and JoinTime
  // seconds.
  fileprivate func _requestTxOpportunity(eventSource: EventSource) {
    guard !_jointimer.isRunning else { return }
    _scheduleTxOpportunity(eventSource: eventSource)
  }

  private func _scheduleTxOpportunity(eventSource: EventSource) {
    _logger.trace("\(self): \(eventSource) requests TX opportunity")

    guard let controller else { return }
    let joinTime = controller.timerConfiguration.joinTime
    let interval: Duration = _type == .pointToPoint ? .zero :
      .nanoseconds(Int64.random(in: 0..<joinTime.nanoseconds))

    _jointimer.start(interval: interval)
  }

  private func _onTxOpportunity(isolation: isolated A) async throws {
    _assertIsolatedToApplication()

    let eventSource = EventSource.joinTimer

    // Suppress TX opportunities while RX is processing to prevent interleaving
    if _rxInProgress {
      await Task.yield()
      _scheduleTxOpportunity(eventSource: eventSource)
      return
    }

    if _type == .pointToPoint, let controller {
      let rateLimit = controller.timerConfiguration.joinTime * 1.5
      let now = ContinuousClock.now

      _transmissionOpportunityTimestamps.removeAll { now - $0 >= rateLimit }

      if _transmissionOpportunityTimestamps.count >= 3 {
        if let oldestTimestamp = _transmissionOpportunityTimestamps.first {
          let timeUntilExpiry = rateLimit - (now - oldestTimestamp)
          _logger
            .trace(
              "\(self): rate limit reached, retrying in \(timeUntilExpiry)"
            )
          _jointimer?.start(interval: timeUntilExpiry)
        }
        return
      }
    }

    // this will send a .tx/.txLA event to all attributes which will then make
    // the appropriate state transitions, potentially triggering the encoding
    // of a vector
    switch _leaveAll.state {
    case .Active:
      // encode attributes first with current registrar states, then process LeaveAll
      try _apply(protocolEvent: .txLA, eventSource: eventSource)
      // sets LeaveAll to passive and emits sLA action
      try _handleLeaveAll(protocolEvent: .tx, eventSource: eventSource)
    case .Passive:
      try _apply(protocolEvent: .tx, eventSource: eventSource)
    }

    let didTransmit = try await _tx()

    // If events remain (e.g., arrived during TX processing or didn't fit in PDU),
    // request another TX opportunity. Note: isRunning returns false at this point
    // because _fire() cleared the task reference before calling this callback, but
    // applicant state transitions may have already scheduled a new timer via
    // _requestTxOpportunity(). Only reschedule if we have pending work.
    if didTransmit, _type == .pointToPoint {
      _transmissionOpportunityTimestamps.append(ContinuousClock.now)
    }

    // if events remain (e.g., arrived during TX processing or didn't fit in PDU),
    // request another TX opportunity
    if !_enqueuedEvents.isEmpty {
      _scheduleTxOpportunity(eventSource: eventSource)
    }
  }

  private func _findOrCreateAttribute(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    matching filter: AttributeValueFilter,
    createIfMissing: Bool
  ) throws -> _AttributeValue<A> {
    _assertIsolatedToApplication()

    if let attributeValue = _attributes[attributeType]?
      .first(where: { $0.matches(attributeType: attributeType, matching: filter) })
    {
      return attributeValue
    }

    guard createIfMissing else {
      throw MRPError.invalidAttributeValue
    }

    guard let filterValue = try filter._value else {
      throw MRPError.internalError
    }

    let attributeValue = _AttributeValue(
      participant: self,
      type: attributeType,
      subtype: attributeSubtype,
      value: filterValue
    )
    if let index = _attributes.index(forKey: attributeType) {
      _attributes.values[index].insert(attributeValue)
    } else {
      _attributes[attributeType] = [attributeValue]
    }
    return attributeValue
  }

  private func _findRegisteredAttributes(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter = .matchAny
  ) -> [_AttributeValue<A>] {
    _assertIsolatedToApplication()

    return (_attributes[attributeType] ?? [])
      .filter {
        $0.matches(attributeType: attributeType, matching: filter) && $0.isRegistered
      }
  }

  fileprivate func _gcAttributeValue(_ attributeValue: _AttributeValue<A>) {
    _assertIsolatedToApplication()

    if let index = _attributes.index(forKey: attributeValue.attributeType) {
      _attributes.values[index].remove(attributeValue)
      if _attributes.values[index].isEmpty {
        _attributes.removeValue(forKey: attributeValue.attributeType)
      }
    }
  }

  private func _handleAttributeValue(
    _ attributeValue: _AttributeValue<A>,
    protocolEvent: ProtocolEvent,
    eventSource: EventSource
  ) throws {
    try attributeValue.handle(
      protocolEvent: protocolEvent,
      eventSource: eventSource
    )
  }

  private func _chunkAttributeEvents(_ attributeEvents: [EnqueuedEvent<A>.AttributeEvent])
    -> [[EnqueuedEvent<A>.AttributeEvent]]
  {
    guard !attributeEvents.isEmpty else { return [] }

    // Helper function to trim trailing optional events and add chunk if non-empty
    func finalizeChunk(_ chunk: inout [EnqueuedEvent<A>.AttributeEvent]) {
      // Optional events at the end don't reduce chunk count, so omit them
      while !chunk.isEmpty && chunk.last!.encodingOptional {
        chunk.removeLast()
      }
      if !chunk.isEmpty {
        chunks.append(chunk)
        chunk = []
      }
    }

    var chunks: [[EnqueuedEvent<A>.AttributeEvent]] = []
    var currentChunk: [EnqueuedEvent<A>.AttributeEvent] = []
    var expectedIndex = attributeEvents[0].attributeValue.index

    for attributeEvent in attributeEvents {
      if attributeEvent.attributeValue.index == expectedIndex {
        // Event is sequential with current chunk, include it for now
        currentChunk.append(attributeEvent)
        expectedIndex += 1
      } else {
        // Event would start a new chunk - finish current chunk first
        finalizeChunk(&currentChunk)

        // Start new chunk with this event (if not optional)
        // Optional events that would start a new chunk are skipped entirely
        if !attributeEvent.encodingOptional {
          currentChunk = [attributeEvent]
          expectedIndex = attributeEvent.attributeValue.index + 1
        }
      }
    }

    // Handle the last chunk
    finalizeChunk(&currentChunk)

    return chunks
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
      let attributeEventChunks = _chunkAttributeEvents(attributeEvents)

      var vectorAttributes: [VectorAttribute<AnyValue>] = attributeEventChunks
        .compactMap { attributeEventChunk in
          guard !attributeEventChunk.isEmpty else { return nil }

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

      if vectorAttributes.isEmpty, leaveAll {
        let vectorAttribute = try VectorAttribute<AnyValue>(
          leaveAllEvent: .LeaveAll,
          firstValue: AnyValue(application.makeNullValue(for: attributeType)),
          attributeEvents: [],
          applicationEvents: nil
        )
        vectorAttributes = [vectorAttribute]
      }
      if !vectorAttributes.isEmpty {
        messages.append(Message(attributeType: attributeType, attributeList: vectorAttributes))
      }
    }

    return messages
  }

  private func _txEnqueue(_ event: EnqueuedEvent<A>, eventSource: EventSource) {
    _assertIsolatedToApplication()

    if let index = _enqueuedEvents.index(forKey: event.attributeType) {
      if let eventIndex = _enqueuedEvents.values[index]
        .firstIndex(where: { $0 == event })
      {
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
    attributeValue: _AttributeValue<A>,
    encodingOptional: Bool,
    eventSource: EventSource
  ) {
    let event = EnqueuedEvent<A>.AttributeEvent(
      attributeEvent: attributeEvent,
      attributeValue: attributeValue,
      encodingOptional: encodingOptional
    )
    _txEnqueue(.attributeEvent(event), eventSource: eventSource)
  }

  private func _txEnqueueLeaveAllEvents(eventSource: EventSource) throws {
    guard let application else { throw MRPError.internalError }
    for attributeType in application.validAttributeTypes {
      _txEnqueue(.leaveAllEvent(attributeType), eventSource: eventSource)
    }
  }

  // handle an event in the LeaveAll state machine (10.5)
  private func _handleLeaveAll(
    protocolEvent event: ProtocolEvent,
    eventSource: EventSource
  ) throws {
    let (action, txOpportunity) = _leaveAll.action(for: event) // may update state

    if txOpportunity {
      _requestTxOpportunity(eventSource: .leaveAll)
    }

    switch action {
    case .startLeaveAllTimer:
      _leaveAll.startLeaveAllTimer()
    case .sLA:
      // a) The LeaveAll state machine associated with that instance of the
      // Applicant or Registrar state machine performs the sLA action
      // (10.7.6.6); or a MRPDU is received with a LeaveAll
      _logger.debug("\(self): sending leave all events, source \(eventSource)")
      // the rLA! event is responsible for starting the leave timer on
      // registered attributes (Table 10-4), as well as requesting the
      // applicant to redeclare attributes (Table 10-3).
      try _apply(protocolEvent: .rLA, eventSource: eventSource)
      try _txEnqueueLeaveAllEvents(eventSource: eventSource)
    default:
      break
    }
  }

  private func _txDequeue() throws -> MRPDU? {
    _assertIsolatedToApplication()

    guard let application else { throw MRPError.internalError }

    let enqueuedMessages = try _packMessages(with: _enqueuedEvents)
    _enqueuedEvents.removeAll()

    guard !enqueuedMessages.isEmpty else { return nil }

    let pdu = MRPDU(
      protocolVersion: application.protocolVersion,
      messages: enqueuedMessages
    )

    return pdu
  }

  private func rx(message: Message, eventSource: EventSource, leaveAll: inout Bool) throws {
    for vectorAttribute in message.attributeList {
      // 10.6 Protocol operation: process LeaveAll first.
      if vectorAttribute.leaveAllEvent == .LeaveAll {
        try _apply(
          attributeType: message.attributeType,
          protocolEvent: .rLA,
          eventSource: eventSource
        )
        leaveAll = true
      }

      let packedEvents = try vectorAttribute.attributeEvents
      guard packedEvents.count >= vectorAttribute.numberOfValues else {
        throw MRPError.badVectorAttribute
      }
      for i in 0..<Int(vectorAttribute.numberOfValues) {
        let attributeEvent = packedEvents[i]
        let attributeSubtype = vectorAttribute.applicationEvents?[i]

        guard let attribute = try? _findOrCreateAttribute(
          attributeType: message.attributeType,
          attributeSubtype: attributeSubtype,
          matching: .matchRelative((vectorAttribute.firstValue.value, UInt64(i))),
          createIfMissing: true
        ) else { continue }

        // if a Bridge receives a MSRP JoinIn/JoinMt message with a different
        // attribute subtype, it should behave as if a rLv! event with immediate
        // leavetimer expiration was received.
        if attributeEvent.protocolEvent == .rJoinIn || attributeEvent.protocolEvent == .rJoinMt,
           let attributeSubtype, attribute.attributeSubtype != attributeSubtype
        {
          _logger
            .debug(
              "\(self): \(eventSource) declared attribute \(attribute) with new subtype \(attributeSubtype); replacing"
            )
          try? attribute.willReplaceSubtype(eventSource: eventSource)
          attribute.attributeSubtype = attributeSubtype
        }

        try _handleAttributeValue(
          attribute,
          protocolEvent: attributeEvent.protocolEvent,
          eventSource: eventSource
        )
      }
    }
  }

  func rx(pdu: MRPDU, sourceMacAddress: EUI48) throws {
    _assertIsolatedToApplication()

    _debugLogPdu(pdu, direction: .rx)

    _rxInProgress = true
    defer { _rxInProgress = false }

    var leaveAll = false
    let eventSource: EventSource = _isEqualMacAddress(
      sourceMacAddress,
      port.macAddress
    ) ? .local : .peer
    for message in pdu.messages {
      try rx(message: message, eventSource: eventSource, leaveAll: &leaveAll)
    }
    if leaveAll {
      try _handleLeaveAll(protocolEvent: .rLA, eventSource: eventSource)
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
    // TODO: add flags for when attribute is empty, so Applicant State Machine can
    // ignore transition to LO from VO/AO/QO when receiving rLA!, txLA!, or txLAF!
    return flags
  }

  private enum _Direction: CustomStringConvertible {
    case tx
    case rx

    var description: String {
      switch self {
      case .tx: "TX"
      case .rx: "RX"
      }
    }
  }

  private func _debugLogAttribute(
    attributeType: AttributeType,
    _ attribute: VectorAttribute<AnyValue>,
    direction: _Direction
  ) {
    let threePackedEventsString = try! attribute.attributeEvents
      .compactMap { String(describing: $0) }.joined(separator: ", ")
    let fourPackedEventsString = attribute.applicationEvents?
      .prefix(Int(attribute.numberOfValues))
      .compactMap { String(describing: MSRPAttributeSubtype(rawValue: $0)!) }
      .joined(separator: ", ")
    let firstValueString = attribute
      .numberOfValues > 0 ? String(describing: attribute.firstValue) : "--"

    if let fourPackedEventsString {
      _logger
        .debug(
          "\(self): \(direction): AT \(attributeType) \(attribute.leaveAllEvent == .LeaveAll ? "LA" : "--") AV \(firstValueString) AE [\(threePackedEventsString)] AS [\(fourPackedEventsString)]"
        )
    } else {
      _logger
        .debug(
          "\(self): \(direction): AT \(attributeType) \(attribute.leaveAllEvent == .LeaveAll ? "LA" : "--") AV \(firstValueString) AE [\(threePackedEventsString)]"
        )
    }
  }

  private func _debugLogMessage(_ message: Message, direction: _Direction) {
    for attribute in message.attributeList {
      _debugLogAttribute(attributeType: message.attributeType, attribute, direction: direction)
    }
  }

  private func _debugLogPdu(_ pdu: MRPDU, direction: _Direction) {
    guard _logger.logLevel <= .debug else { return }
    _logger
      .debug("\(self): \(direction): -------------------------------------------------------------")
    for message in pdu.messages {
      _debugLogMessage(message, direction: direction)
    }
    _logger
      .debug("\(self): \(direction): -------------------------------------------------------------")
  }
}

// MARK: - public APIs for use by applications

public extension Participant {
  func findAttribute(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter
  ) -> (AttributeSubtype?, any Value)? {
    findAttributes(attributeType: attributeType, matching: filter).first
  }

  func findAttributes(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter = .matchAny
  ) -> [(AttributeSubtype?, any Value)] {
    _findRegisteredAttributes(attributeType: attributeType, matching: filter).map { (
      $0.attributeSubtype,
      $0.unwrappedValue
    ) }
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
  func flush() throws {
    try _apply(protocolEvent: .Flush, eventSource: .internal)
    try _handleLeaveAll(protocolEvent: .Flush, eventSource: .internal)
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
  func redeclare() throws {
    try _apply(protocolEvent: .ReDeclare, eventSource: .internal)
  }

  func join(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype? = nil,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) throws {
    let attribute = try _findOrCreateAttribute(
      attributeType: attributeType,
      attributeSubtype: attributeSubtype,
      matching: .matchEqual(attributeValue), // don't match on subtype, we want to replace it
      createIfMissing: true
    )

    if !isNew, let attributeSubtype, attribute.attributeSubtype != attributeSubtype { _logger
      .debug(
        "\(self): \(eventSource) declared attribute \(attribute) with new subtype \(attributeSubtype); replacing"
      )

      try? attribute.willReplaceSubtype(eventSource: eventSource)
      attribute.attributeSubtype = attributeSubtype
    }

    try _handleAttributeValue(
      attribute,
      protocolEvent: isNew ? .New : .Join,
      eventSource: eventSource
    )
  }

  func leave(
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype? = nil,
    attributeValue: some Value,
    eventSource: EventSource
  ) throws {
    let attribute = try _findOrCreateAttribute(
      attributeType: attributeType,
      attributeSubtype: attributeSubtype,
      matching: .matchEqual(attributeValue),
      createIfMissing: false
    )

    try _handleAttributeValue(
      attribute,
      protocolEvent: .Lv,
      eventSource: eventSource
    )
  }

  func deregister(
    attributeType: AttributeType,
    attributeValue: some Value,
    eventSource: EventSource
  ) throws {
    let attribute = try _findOrCreateAttribute(
      attributeType: attributeType,
      attributeSubtype: nil,
      matching: .matchEqual(attributeValue),
      createIfMissing: false
    )

    try _handleAttributeValue(
      attribute,
      protocolEvent: .rLvNow,
      eventSource: eventSource
    )
  }

  func periodic() throws {
    _logger.trace("\(self): running periodic")
    try _apply(protocolEvent: .periodic, eventSource: .periodicTimer)
    // timer is restarted by the caller
  }
}

// MARK: - for use by REST APIs

extension Participant {
  private func findAllAttributesUnchecked(
    matching filter: AttributeValueFilter,
    isolation: isolated A
  ) -> [AttributeValue] {
    _assertIsolatedToApplication()

    return _attributes.values.flatMap { $0 }
      .map { AttributeValue(
        attributeType: $0.attributeType,
        attributeSubtype: $0.attributeSubtype,
        attributeValue: $0.unwrappedValue,
        applicantState: $0.applicantState,
        registrarState: $0.registrarState
      ) }
  }

  func findAllAttributes(
    matching filter: AttributeValueFilter = .matchAny
  ) async -> [AttributeValue] {
    guard let application else { return [] }
    return await findAllAttributesUnchecked(matching: filter, isolation: application)
  }

  func findAllAttributesUnchecked(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter,
    isolation: isolated A
  ) -> [AttributeValue] {
    _assertIsolatedToApplication()

    return (_attributes[attributeType] ?? [])
      .filter { $0.matches(attributeType: attributeType, matching: filter) }
      .map { AttributeValue(
        attributeType: attributeType,
        attributeSubtype: $0.attributeSubtype,
        attributeValue: $0.unwrappedValue,
        applicantState: $0.applicantState,
        registrarState: $0.registrarState
      ) }
  }

  func findAllAttributes(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter = .matchAny
  ) async -> [AttributeValue] {
    guard let application else { return [] }
    return await findAllAttributesUnchecked(
      attributeType: attributeType,
      matching: filter,
      isolation: application
    )
  }
}

private typealias ParticipantApplyFunction<A: Application> =
  @Sendable (_AttributeValue<A>) throws -> ()

private final class _AttributeValue<A: Application>: Sendable, Hashable, Equatable,
  CustomStringConvertible
{
  typealias P = Participant<A>

  // don't match subtype on comparison, we don't want to emit PDUs with
  // multiple subtype values (at least, for MSRP). We only match the index
  // because we can only have one value for each (attributeType, index).
  static func == (lhs: _AttributeValue<A>, rhs: _AttributeValue<A>) -> Bool {
    lhs.matches(
      attributeType: rhs.attributeType,
      matching: .matchIndex(rhs.unwrappedValue)
    )
  }

  private let _participant: Weak<P>
  private let _attributeSubtype: Mutex<AttributeSubtype?>

  private let applicant = Applicant() // A per-Attribute Applicant state machine (10.7.7)
  // note registrar is not mutated outside init() so it does not need a mutex
  private nonisolated(unsafe) var registrar: Registrar? // A per-Attribute Registrar state machine
  // (10.7.8)

  let attributeType: AttributeType
  let value: AnyValue

  let counters = Mutex(EventCounters<A>())

  var index: UInt64 { value.index }
  var participant: P? { _participant.object }
  var unwrappedValue: any Value { value.value }

  var attributeSubtype: AttributeSubtype? {
    get {
      _attributeSubtype.withLock { $0 }
    }

    set {
      _attributeSubtype.withLock { $0 = newValue }
    }
  }

  var applicantState: Applicant.State {
    applicant.state
  }

  var isDeclared: Bool {
    applicantState.isDeclared
  }

  var registrarState: Registrar.State? {
    registrar?.state
  }

  var isRegistered: Bool {
    registrarState?.isRegistered ?? false
  }

  // Returns true if attribute can be garbage collected.
  // An attribute is safe to GC if:
  // - We are not running the Registrar state machine, OR the registrar state is MT (not registered)
  // - AND the applicant is not declaring the attribute
  fileprivate var canGC: Bool {
    !isRegistered && !isDeclared
  }

  nonisolated var description: String {
    if let attributeSubtype {
      "_AttributeValue(attributeType: \(attributeType), attributeSubtype: \(attributeSubtype), attributeValue: \(value), A \(applicant) R \(registrar?.description ?? "-"))"
    } else {
      "_AttributeValue(attributeType: \(attributeType), attributeValue: \(value), A \(applicant) R \(registrar?.description ?? "-"))"
    }
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
    _attributeSubtype = .init(subtype)
    self.value = value
  }

  init(participant: P, type: AttributeType, subtype: AttributeSubtype?, value: some Value) {
    precondition(!(value is AnyValue))
    _participant = Weak(participant)
    attributeType = type
    _attributeSubtype = .init(subtype)
    self.value = AnyValue(value)
    if participant._type != .applicantOnly {
      registrar = Registrar(leaveTime: participant.controller!.timerConfiguration
        .leaveTime)
      { @Sendable [self] in
        guard let application = participant.application else { return }
        try await _onLeaveTimerExpired(isolation: application)
      }
    }
  }

  deinit {
    registrar?.stopLeaveTimer()
  }

  private func _onLeaveTimerExpired(isolation: isolated A) throws {
    try handle(
      protocolEvent: .leavetimer,
      eventSource: .leaveTimer
    )
  }

  func hash(into hasher: inout Hasher) {
    attributeType.hash(into: &hasher)
    value.index.hash(into: &hasher)
  }

  func matches(
    attributeType filterAttributeType: AttributeType?,
    matching filter: AttributeValueFilter
  ) -> Bool {
    if let filterAttributeType {
      guard attributeType == filterAttributeType else { return false }
    }

    do {
      switch filter {
      case .matchAny:
        return true
      case let .matchAnyIndex(index):
        return self.index == index
      case let .matchIndex(value):
        return index == value.index
      case let .matchEqual(value):
        return self.value == value.eraseToAny()
      case .matchRelative(let (value, offset)):
        return try self.value == value.makeValue(relativeTo: offset).eraseToAny()
      }
    } catch {
      return false
    }
  }

  private func _getEventContext(
    for event: ProtocolEvent,
    eventSource: EventSource,
    isReplacingSubtype: Bool,
    participant: P
  ) throws -> EventContext<A> {
    try EventContext(
      participant: participant,
      event: event,
      eventSource: eventSource,
      attributeType: attributeType,
      attributeSubtype: attributeSubtype,
      attributeValue: unwrappedValue,
      smFlags: participant._getSmFlags(for: attributeType).union(isReplacingSubtype ? .isReplacingSubtype : []),
      applicant: applicant,
      registrar: registrar
    )
  }

  fileprivate func handle(
    protocolEvent event: ProtocolEvent,
    eventSource: EventSource,
    isReplacingSubtype: Bool = false
  ) throws {
    guard let participant else { throw MRPError.internalError }
    try _handle(
      protocolEvent: event,
      eventSource: eventSource,
      isReplacingSubtype: isReplacingSubtype,
      participant: participant
    )
  }

  private func _handle(
    protocolEvent event: ProtocolEvent,
    eventSource: EventSource,
    isReplacingSubtype: Bool = false,
    participant: P
  ) throws {
    let context = try _getEventContext(
      for: event,
      eventSource: eventSource,
      isReplacingSubtype: isReplacingSubtype,
      participant: participant
    )

    try _handleRegistrar(context: context, participant: context.participant)
    try _handleApplicant(context: context, participant: context.participant)

    // remove attribute entirely if it is no longer declared or registered
    if !isReplacingSubtype, canGC { participant._gcAttributeValue(self) }
  }

  private func _handleApplicant(
    context: EventContext<A>,
    participant: P
  ) throws {
    participant._logger.trace("\(context.participant): handling applicant \(context)")

    let isRegistered = registrar?.state.isRegistered ?? false
    let (applicantAction, txOpportunity) = applicant.action(
      for: context.event,
      flags: context.smFlags.union(isRegistered ? .isRegistered : [])
    )

    if let applicantAction {
      participant._logger
        .trace(
          "\(context.participant): applicant action for event \(context.event): \(applicantAction)"
        )

      let attributeEvent: AttributeEvent

      switch applicantAction {
      case .sN:
        // The AttributeEvent value New is encoded in the Vector as specified in
        // 10.7.6.1.
        attributeEvent = .New
      case .sJ:
        fallthrough
      case .sJ_:
        // The [sJ] variant indicates that the action is only necessary in cases
        // where transmitting the value, rather than terminating a vector and
        // starting a new one, makes for more optimal encoding; i.e.,
        // transmitting the value is not necessary for correct protocol
        // operation.
        attributeEvent = (registrar?.state == .IN) ? .JoinIn : .JoinMt
      case .sL:
        fallthrough
      case .sL_:
        attributeEvent = .Lv
      case .s:
        fallthrough
      case .s_:
        attributeEvent = (registrar?.state == .IN) ? .In : .Mt
      }

      participant._txEnqueue(
        attributeEvent: attributeEvent,
        attributeValue: self,
        encodingOptional: applicantAction.encodingOptional,
        eventSource: context.eventSource
      )

      counters.withLock { $0.count(context: context, attributeEvent: attributeEvent) }
    }

    if txOpportunity {
      participant._requestTxOpportunity(eventSource: context.eventSource)
    }
  }

  private func _handleRegistrar(
    context: EventContext<A>,
    participant: P
  ) throws {
    context.participant._logger.trace("\(context.participant): handling registrar \(context)")

    guard let registrarAction = context.registrar?
      .action(for: context.event, flags: context.smFlags)
    else {
      return
    }

    context.participant._logger
      .trace(
        "\(context.participant): registrar action for event \(context.event): \(registrarAction)"
      )

    guard let application = context.participant.application else { throw MRPError.internalError }

    // to avoid synchronization issues, when we replace an attribute with
    // rLvNow, suppress the leave indication; MSRP will correctly recover with
    // the subsequent join
    guard !context.smFlags.contains(.isReplacingSubtype) else { return }

    Task { @Sendable in
      switch registrarAction {
      case .New:
        fallthrough
      case .Join:
        try await application.joinIndicated(
          contextIdentifier: context.participant.contextIdentifier,
          port: context.participant.port,
          attributeType: context.attributeType,
          attributeSubtype: context.attributeSubtype,
          attributeValue: context.attributeValue,
          isNew: registrarAction == .New,
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

  // called only when replacing attribute; suppresses GC and leave indication
  fileprivate func willReplaceSubtype(eventSource: EventSource) throws {
    try handle(
      protocolEvent: .rLvNow,
      eventSource: eventSource,
      isReplacingSubtype: true
    )
    precondition(!isRegistered)
  }
}

private extension AttributeValueFilter {
  var _value: (any Value)? {
    get throws {
      switch self {
      case .matchAny:
        fallthrough
      case .matchAnyIndex:
        return nil
      case let .matchIndex(value):
        fallthrough
      case let .matchEqual(value):
        return value
      case .matchRelative(let (value, index)):
        return try value.makeValue(relativeTo: index)
      }
    }
  }
}
