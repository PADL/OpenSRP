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

import AsyncQueue
import IEEE802
import Logging
import Synchronization

enum ParticipantType {
  case full
  case pointToPoint
  case newOnly
  case applicantOnly
}

private enum EnqueuedEvent<A: Application>: CustomStringConvertible {
  struct AttributeEvent: CustomStringConvertible {
    let attributeEvent: MRP.AttributeEvent
    let attributeValue: _AttributeValue<A>
    let encodingOptional: Bool

    var description: String {
      "attributeEvent: \(attributeEvent), attributeValue: \(attributeValue), encodingOptional: \(encodingOptional)"
    }
  }

  case attributeEvent(AttributeEvent)
  case leaveAllEvent(AttributeType)

  // Coalescing key: the attribute index (nil for LeaveAll). A plain integer
  // so dedup/sort avoid the existential == on the boxed `any Value`.
  var index: UInt64? {
    switch self {
    case let .attributeEvent(attributeEvent):
      attributeEvent.attributeValue.index
    case .leaveAllEvent:
      nil
    }
  }

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

  private typealias EnqueuedEvents = [AttributeType: [UInt64?: EnqueuedEvent<A>]]

  private var _attributes = [AttributeType: Set<_AttributeValue<A>>]()
  fileprivate var _generation: UInt64 = 0
  private var _enqueuedEvents = EnqueuedEvents()
  private nonisolated(unsafe) var _leaveAll: LeaveAll!
  private nonisolated(unsafe) var _jointimer: Timer!
  private var _transmissionOpportunityTimestamps: [ContinuousClock.Instant] = []

  private nonisolated let _controller: Weak<MRPController<A.P>>
  private nonisolated let _application: Weak<A>

  fileprivate let _logger: Logger
  fileprivate let _type: ParticipantType
  fileprivate let _queue = ActorQueue<A>()
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
    _queue.adoptExecutionContext(of: application)
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
    _jointimer = Timer(label: "jointimer") { @Sendable [weak self] in
      guard let self, let application else { return }
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
    { @Sendable [weak self] in
      guard let self, let application else { return }
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
    // §10.7.11: the transmit provisions follow operPointToPointMAC (the MAC),
    // independent of whether the point-to-point subset Applicant is in use.
    let interval: Duration = port.isPointToPoint ? .zero :
      .nanoseconds(Int64.random(in: 0..<joinTime.nanoseconds))

    _jointimer.start(interval: interval)
  }

  private func _onTxOpportunity(isolation: isolated A) async throws {
    _assertIsolatedToApplication()

    guard let controller else { throw MRPError.internalError }

    let eventSource = EventSource.joinTimer

    // Coalesce a received PDU's propagation into one MRPDU: if its Join/Leave indications are
    // still in flight, park until they drain (resumed the moment the count hits zero) rather than
    // transmitting mid-batch.
    if controller._propagationBarrier.count > 0 {
      await controller._propagationBarrier.waitUntilZero()
    }

    if port.isPointToPoint {
      let rateLimit = controller.timerConfiguration.joinTime * 1.5
      let now = ContinuousClock.now

      // keep the window closed on the left so any 1.5xJoinTime period holds <=3
      _transmissionOpportunityTimestamps.removeAll { now - $0 > rateLimit }

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
    if didTransmit, port.isPointToPoint {
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
    createIfMissing: Bool,
    administrativelyRegistered: Bool = false
  ) throws -> _AttributeValue<A> {
    _assertIsolatedToApplication()

    if let attributeValue = _attributes[attributeType]?
      .first(where: { $0.matches(attributeType: attributeType, matching: filter) })
    {
      // an existing (dynamically created) attribute transitions to Registration Fixed:
      // the administrative registration is immutable, so replace the attribute
      if administrativelyRegistered, !attributeValue.isAdministrativelyRegistered {
        return _replaceAttribute(attributeValue, administrativelyRegistered: true)
      }
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
      value: filterValue,
      administrativelyRegistered: administrativelyRegistered
    )
    _attributes[attributeType, default: []].insert(attributeValue)
    return attributeValue
  }

  // Replace an attribute to change its (immutable) Registrar administrative registration,
  // transplanting the live Applicant so declared state is preserved. The old Registrar's
  // leavetimer is stopped by its deinit; any underlying dynamic registration is discarded
  // (peers re-Join it within a LeaveAll cycle).
  private func _replaceAttribute(
    _ attribute: _AttributeValue<A>,
    administrativelyRegistered: Bool
  ) -> _AttributeValue<A> {
    _assertIsolatedToApplication()

    _gcAttributeValue(attribute)
    let replacement = _AttributeValue(
      participant: self,
      type: attribute.attributeType,
      subtype: attribute.attributeSubtype,
      value: attribute.unwrappedValue,
      applicant: attribute.applicant,
      administrativelyRegistered: administrativelyRegistered
    )
    _attributes[replacement.attributeType, default: []].insert(replacement)
    return replacement
  }

  // the most recently registered value (by Registrar-IN order) matching the filter, or nil if none
  // is registered; distinguishes several coexisting same-index registrations by recency.
  func newestRegisteredValue(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter = .matchAny
  ) -> (any Value)? {
    _findRegisteredAttributes(attributeType: attributeType, matching: filter)
      .max { $0.generation < $1.generation }?
      .unwrappedValue
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

    // Coalesce only an exact increment chain: value[i] must equal value[i-1]+1, the
    // sequence the receiver reconstructs from FirstValue. A consecutive index isn't enough.
    func chains(after previous: _AttributeValue<A>, to candidate: _AttributeValue<A>) -> Bool {
      guard let expected = try? previous.value.makeValue(relativeTo: 1) else { return false }
      // Coalescing needs the receiver's reconstruction to encode to identical octets, so use the
      // wire-exact `==` (which compares every serialized field, including AccumulatedLatency).
      return expected == candidate.value
    }

    var chunks: [[EnqueuedEvent<A>.AttributeEvent]] = []
    var currentChunk: [EnqueuedEvent<A>.AttributeEvent] = []

    for attributeEvent in attributeEvents {
      if let previous = currentChunk.last,
         chains(after: previous.attributeValue, to: attributeEvent.attributeValue)
      {
        // Value continues the increment chain, include it for now
        currentChunk.append(attributeEvent)
      } else {
        // Event would start a new chunk - finish current chunk first
        finalizeChunk(&currentChunk)

        // Start new chunk with this event (if not optional)
        // Optional events that would start a new chunk are skipped entirely
        if !attributeEvent.encodingOptional {
          currentChunk = [attributeEvent]
        }
      }
    }

    // Handle the last chunk
    finalizeChunk(&currentChunk)

    return chunks
  }

  // swiftformat:disable preferKeyPath
  // Closures, not \.keyPath: on this transmit hot path a keypath literal over the generic
  // event type builds a runtime KeyPath object and projects through it; a closure calls the
  // getter directly. Do not let preferKeyPath rewrite these back.
  private func _packMessages(with events: EnqueuedEvents) throws -> [Message] {
    guard let application else { throw MRPError.internalError }

    var messages = [Message]()

    for (attributeType, eventValue) in events {
      let leaveAll = eventValue.values.contains { $0.isLeaveAll }
      // Sort Int positions against once-read indices, then gather: sorting the class-backed
      // events (or a tuple) would retain/release -- or instantiate metadata -- on every swap.
      let events = eventValue.values.filter { !$0.isLeaveAll }.map { $0.unsafeAttributeEvent }
      let keys = events.map { $0.attributeValue.index }
      let attributeEvents = events.indices.sorted { keys[$0] < keys[$1] }.map { events[$0] }
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
            attributeEvents: Array(attributeEventChunk.map { $0.attributeEvent }),
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

  // swiftformat:enable preferKeyPath

  private func _txEnqueue(_ event: EnqueuedEvent<A>, eventSource: EventSource) {
    _assertIsolatedToApplication()
    _enqueuedEvents[event.attributeType, default: [:]][event.index] = event
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

    return MRPDU(
      protocolVersion: application.protocolVersion,
      messages: enqueuedMessages
    )
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

        // 35.2.6: a re-registration with a changed FourPackedEvent behaves as leave+rejoin; apply on
        // any registration event incl. New so a New re-declaration can't retain a stale subtype.
        if attributeEvent.protocolEvent.indicatesRegistration,
           let attributeSubtype, attribute.attributeSubtype != attributeSubtype
        {
          _logger
            .debug(
              "\(self): \(eventSource) declared attribute \(attribute) with new subtype \(attributeSubtype); replacing"
            )
          try? attribute.willReplace(eventSource: eventSource)
          attribute.attributeSubtype = attributeSubtype
        }

        // a same-identity payload change (Talker latency / FailureInfo) resets the Registrar (leave
        // suppressed), then adopts the new value so the rJoinIn re-indicates it via Join
        if attributeEvent.protocolEvent.indicatesRegistration,
           let received = try? vectorAttribute.firstValue.value.makeValue(relativeTo: UInt64(i)),
           attribute.value != received.eraseToAny()
        {
          try? attribute.willReplace(eventSource: eventSource)
          attribute.updateValue(received)
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

    var leaveAll = false
    // All received PDUs are peer-sourced: we snoop MRP via an ingress-only NFLOG trap, so our own
    // transmissions never re-enter here (self-MAC frames were formerly classified EventSource.local
    // for a co-resident kernel applicant that does not exist).
    let eventSource: EventSource = .peer
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
    // Registrar (10.7.8) and Applicant (10.7.7) admin controls are orthogonal: derive the
    // Registrar's fixed/forbidden flags and the Applicant's New-Only flag independently.
    let administrativeControl = try application.administrativeControl(for: attributeType)
    switch administrativeControl.registrar {
    case .normalRegistration:
      break
    case .registrationFixed:
      flags.insert(.registrationFixedNewPropagated)
    case .registrationForbidden:
      flags.insert(.registrationForbidden)
    }
    switch administrativeControl.applicant {
    case .normalParticipant:
      break
    case .newOnlyParticipant:
      flags.insert(.applicantOnlyParticipant)
    }
    if application.registrarLeaveImmediate { flags.insert(.leaveImmediate) }
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
    // tolerate malformed, attacker-controlled events: the debug log must never abort the daemon
    // (10.8.3.3 -- a badly formed MRPDU is discarded by rx, not fatal). Reserved values render "?".
    let threePackedEventsString = ((try? attribute.attributeEvents)?
      .compactMap { String(describing: $0) }.joined(separator: ", ")) ?? "?"
    let fourPackedEventsString = attribute.applicationEvents?
      .prefix(Int(attribute.numberOfValues))
      .map { MSRPAttributeSubtype(rawValue: $0).map { String(describing: $0) } ?? "?" }
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

  // 10.3 NOTE: when this Port leaves the active topology it transmits a Leave for every attribute
  // it has declared. Lv is a MAD_Leave.request to the Applicant, so registrations are unaffected.
  func leave() throws {
    try _apply(protocolEvent: .Lv, eventSource: .internal)
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
      matching: .matchIdentity(attributeValue), // don't match on subtype, we want to replace it
      createIfMissing: true
    )

    if attribute.value != attributeValue.eraseToAny() {
      attribute.updateValue(attributeValue)
      // re-arm a quiet applicant with periodic!
      try _handleAttributeValue(attribute, protocolEvent: .periodic, eventSource: eventSource)
    }

    // apply a changed subtype even when re-declaring New: an existing attribute (e.g. a merged
    // listener propagated during a topology change) must not emit New carrying the stale subtype.
    if let attributeSubtype, attribute.attributeSubtype != attributeSubtype { _logger
      .debug(
        "\(self): \(eventSource) declared attribute \(attribute) with new subtype \(attributeSubtype); replacing"
      )

      try? attribute.willReplace(eventSource: eventSource)
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
      matching: .matchIdentity(attributeValue),
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
      matching: .matchIdentity(attributeValue),
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

  // Administratively register an attribute (Registration Fixed, 10.7.2), e.g. realizing a
  // Static VLAN Registration Entry (8.8.2): the Registrar is held IN and ignores MRP messages.
  // 10.7.2 also requires such a port to send In *and JoinIn* messages; that emission rule is
  // applied when the Applicant transmits (see _handleApplicant), so it needs no change here.
  func administrativelyRegister(
    attributeType: AttributeType,
    attributeValue: some Value
  ) throws {
    _ = try _findOrCreateAttribute(
      attributeType: attributeType,
      attributeSubtype: nil,
      matching: .matchIdentity(attributeValue),
      createIfMissing: true,
      administrativelyRegistered: true
    )
  }

  // Clear an administrative registration by replacing the attribute (the registration is
  // immutable), preserving the Applicant. Per the Avnu ProAV clarification of 10.7.2, on
  // return to Normal Registration the state machines act as though rLv! occurred; an idle
  // attribute is then GC'd.
  func administrativelyDeregister(
    attributeType: AttributeType,
    attributeValue: some Value
  ) throws {
    let attribute = try _findOrCreateAttribute(
      attributeType: attributeType,
      attributeSubtype: nil,
      matching: .matchIdentity(attributeValue),
      createIfMissing: false
    )
    guard attribute.isAdministrativelyRegistered else { return }
    let replacement = _replaceAttribute(attribute, administrativelyRegistered: false)
    try _handleAttributeValue(replacement, protocolEvent: .rLv, eventSource: .application)
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

  // synchronous registration check used by MAP leave propagation (10.3 b)
  func isRegisteredUnchecked(
    attributeType: AttributeType,
    matching filter: AttributeValueFilter,
    isolation: isolated A
  ) -> Bool {
    _assertIsolatedToApplication()

    return (_attributes[attributeType] ?? []).contains {
      $0.matches(attributeType: attributeType, matching: filter) && $0.isRegistered
    }
  }
}

private typealias ParticipantApplyFunction<A: Application> =
  @Sendable (_AttributeValue<A>) throws -> ()

private final class _AttributeValue<A: Application>: Sendable, Hashable, Equatable,
  CustomStringConvertible
{
  typealias P = Participant<A>

  // Equality is by identity; hash() keys on index only, so same-index different-identity values
  // (changed Talker fields, a different Domain priority) coexist as hash-collision peers.
  static func == (lhs: _AttributeValue<A>, rhs: _AttributeValue<A>) -> Bool {
    lhs.matches(
      attributeType: rhs.attributeType,
      matching: .matchIdentity(rhs.unwrappedValue)
    )
  }

  private let _participant: Weak<P>
  private let _attributeSubtype: Mutex<AttributeSubtype?>

  fileprivate let applicant: Applicant // A per-Attribute Applicant state machine (10.7.7)
  // note registrar is not mutated outside init() so it does not need a mutex
  private nonisolated(unsafe) var registrar: Registrar? // A per-Attribute Registrar state machine
  // (10.7.8)

  let attributeType: AttributeType
  // 35.2.2.8: the FirstValue is immutable, but a peer may re-declare an existing index with a
  // changed non-FirstValue payload (e.g. AccumulatedLatency). Such updates are applied in place,
  // only under the application actor's isolation (like registrar), and never change the index, so
  // no lock is needed on the isolated read paths and Set/hash stays valid.
  nonisolated(unsafe) var value: AnyValue

  // registration generation (stamped when the Registrar enters IN); lets callers tell which of
  // several same-index registrations is the most recent. Application-isolated like registrar/value.
  nonisolated(unsafe) var generation: UInt64 = 0

  // mutated only from the application-isolated handle() path (like registrar/value), so no lock
  nonisolated(unsafe) var counters = EventCounters<A>()

  var index: UInt64 { value.index }
  var participant: P? { _participant.object }
  var unwrappedValue: any Value { value.value }

  // Update the non-FirstValue payload in place (the index must be unchanged, so hash/equality and
  // the enclosing Set are unaffected); used e.g. to track a peer's changed AccumulatedLatency.
  func updateValue(_ newValue: some Value) {
    precondition(newValue.index == index)
    value = AnyValue(newValue)
  }

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

  fileprivate var isAdministrativelyRegistered: Bool {
    registrar?.isAdministrativelyRegistered ?? false
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
    applicant = Applicant()
    registrar = nil
    attributeType = type
    _attributeSubtype = .init(subtype)
    self.value = value
  }

  // applicant is injectable so that an attribute replaced to change its (immutable)
  // Registrar administrative registration retains its live Applicant state
  init(
    participant: P,
    type: AttributeType,
    subtype: AttributeSubtype?,
    value: some Value,
    applicant: Applicant = Applicant(),
    administrativelyRegistered: Bool = false
  ) {
    precondition(!(value is AnyValue))
    _participant = Weak(participant)
    self.applicant = applicant
    attributeType = type
    _attributeSubtype = .init(subtype)
    self.value = AnyValue(value)
    if participant._type != .applicantOnly {
      guard let controller = participant.controller else { return }
      registrar = Registrar(
        leaveTime: controller.timerConfiguration.leaveTime,
        administrativelyRegistered: administrativelyRegistered
      ) { @Sendable [weak self] in
        guard let self, let application = self.participant?.application else { return }
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
      case let .matchIdentity(value):
        return unwrappedValue.isEqualIdentity(to: value)
      case .matchRelative(let (value, offset)):
        return try unwrappedValue.isEqualIdentity(to: value.makeValue(relativeTo: offset))
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
    var smFlags = try participant._getSmFlags(for: attributeType)
      .union(isReplacingSubtype ? .isReplacingSubtype : [])
    if event.indicatesRegistration, !isRegistered,
       let application = participant.application,
       !application.isRegistrationAllowed(
         for: attributeType,
         attributeSubtype: attributeSubtype,
         attributeValue: unwrappedValue,
         on: participant.port
       )
    {
      smFlags.insert(.registrationForbidden)
    }
    return EventContext(
      participant: participant,
      event: event,
      eventSource: eventSource,
      attributeType: attributeType,
      attributeSubtype: attributeSubtype,
      attributeValue: unwrappedValue,
      smFlags: smFlags,
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

    let wasRegistered = registrar?.state.isRegistered ?? false
    try _handleRegistrar(context: context, participant: context.participant)
    // stamp a new generation on the MT -> IN edge so callers can tell apart several same-index
    // registrations (e.g. a peer that re-declared a Domain at a new priority without a Leave).
    if !wasRegistered, registrar?.state.isRegistered == true {
      participant._generation += 1
      generation = participant._generation
    }
    try _handleApplicant(context: context, participant: context.participant)

    // remove attribute entirely if it is no longer declared or registered
    if !isReplacingSubtype, canGC { participant._gcAttributeValue(self) }
  }

  private func _handleApplicant(
    context: EventContext<A>,
    participant: P
  ) throws {
    participant._logger.trace("\(context.participant): handling applicant \(context)")

    let (applicantAction, txOpportunity) = applicant.action(
      for: context.event,
      registrarState: registrar?.state,
      flags: context.smFlags
    )

    if var applicantAction {
      // A Registration Fixed Registrar never sends In/Empty/Leave: upgrade those to a mandatory
      // JoinIn so peers still register. The optional QA JoinIn (.sJ_) is deliberately left optional
      // (forcing it re-sends every tx opportunity); a new peer registers by the next LeaveAll
      // (10.7.6.3).
      if registrar?.isAdministrativelyRegistered == true,
         applicantAction != .sN, applicantAction != .sJ, applicantAction != .sJ_
      {
        applicantAction = .sJ
      }

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

      counters.count(context: context, attributeEvent: attributeEvent)
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

    // Count this propagation as in flight for the duration of the indication; the increment is
    // synchronous (before the task runs) so all of a received PDU's attributes are counted before
    // any egress tx opportunity fires, letting it coalesce them into one MRPDU (see
    // _onTxOpportunity).
    let controller = context.participant.controller
    controller?._propagationBarrier.enter()
    Task(on: context.participant._queue) { @Sendable _ in
      defer { controller?._propagationBarrier.leave() }
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
  fileprivate func willReplace(eventSource: EventSource) throws {
    try handle(
      protocolEvent: .rLvNow,
      eventSource: eventSource,
      isReplacingSubtype: true
    )
    precondition(!isRegistered)
    participant?._requestTxOpportunity(eventSource: eventSource)
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
      case let .matchIdentity(value):
        return value
      case .matchRelative(let (value, index)):
        return try value.makeValue(relativeTo: index)
      }
    }
  }
}
