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
import Synchronization

protocol BaseApplication: Application where P == P {
  typealias MAPParticipantDictionary = [MAPContextIdentifier: Set<Participant<Self>>]

  var _controller: Weak<MRPController<P>> { get }
  var _participants: MAPParticipantDictionary { get set }
}

protocol BaseApplicationContextObserver<P>: BaseApplication {
  func onContextAdded(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws
  func onContextUpdated(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws
  func onContextRemoved(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws
}

protocol BaseApplicationEventObserver<P>: BaseApplication {
  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) async throws
  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: EventSource
  ) async throws
}

extension BaseApplication {
  var controller: MRPController<P>? { _controller.object }

  public func add(participant: Participant<Self>) throws {
    precondition(
      nonBaseContextsSupported || participant
        .contextIdentifier == MAPBaseSpanningTreeContext
    )
    if let index = _participants.index(forKey: participant.contextIdentifier) {
      _participants.values[index].insert(participant)
    } else {
      _participants[participant.contextIdentifier] = Set([participant])
    }
  }

  public func remove(
    participant: Participant<Self>
  ) throws {
    precondition(
      nonBaseContextsSupported || participant
        .contextIdentifier == MAPBaseSpanningTreeContext
    )
    _participants[participant.contextIdentifier]?.remove(participant)
  }

  @discardableResult
  public func apply<T>(
    for contextIdentifier: MAPContextIdentifier? = nil,
    _ block: AsyncApplyFunction<T>
  ) async rethrows -> [T] {
    let participants: Set<Participant<Self>>? = if let contextIdentifier {
      _participants[contextIdentifier]
    } else {
      Set(_participants.flatMap { Array($1) })
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
  public func apply<T>(
    for contextIdentifier: MAPContextIdentifier? = nil,
    _ block: ApplyFunction<T>
  ) rethrows -> [T] {
    let participants: Set<Participant<Self>>? = if let contextIdentifier {
      _participants[contextIdentifier]
    } else {
      Set(_participants.flatMap { Array($1) })
    }
    var ret = [T]()
    if let participants {
      for participant in participants {
        try ret.append(block(participant))
      }
    }
    return ret
  }

  // applications that support MAP contexts other than the base context will have
  // participants allocated for each context
  private func _isParticipantValid(contextIdentifier: MAPContextIdentifier) -> Bool {
    nonBaseContextsSupported || contextIdentifier == MAPBaseSpanningTreeContext
  }

  public func didAdd(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    if _isParticipantValid(contextIdentifier: contextIdentifier) {
      for port in context {
        guard (try? findParticipant(for: contextIdentifier, port: port)) == nil
        else {
          throw MRPError.portAlreadyExists
        }
        guard let controller else { throw MRPError.internalError }
        let participant = Participant<Self>(
          controller: controller,
          application: self,
          port: port,
          contextIdentifier: contextIdentifier,
          type: controller.flags.contains(.forceFullParticipant) ? .full : nil
        )
        try add(participant: participant)
      }
    }
    // ensure participants are initialized before calling observer
    // also call this regardless of the value of nonBaseContextsSupported, so that
    // MVRP can be advised of VLAN changes on a port
    if let observer = self as? any BaseApplicationContextObserver<P> {
      try await observer.onContextAdded(contextIdentifier: contextIdentifier, with: context)
    }
  }

  public func didUpdate(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    // No Re-declare! here: 10.7.5.3 scopes it to an STP topology change (signaled by
    // _checkTopologyChange). A blanket redeclare on every port update ages out freshly registered
    // attributes. Just advise observers so MVRP tracks VLAN membership changes on the port.
    if let observer = self as? any BaseApplicationContextObserver<P> {
      try await observer.onContextUpdated(contextIdentifier: contextIdentifier, with: context)
    }
  }

  public func didRemove(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    // call observer _before_ removing participants so it can do any other cleanup
    // also call this regardless of the value of nonBaseContextsSupported, so that
    // MVRP can be advised of VLAN changes on a port
    if let observer = self as? any BaseApplicationContextObserver<P> {
      try await observer.onContextRemoved(contextIdentifier: contextIdentifier, with: context)
    }
    if _isParticipantValid(contextIdentifier: contextIdentifier) {
      for port in context {
        let participant = try findParticipant(
          for: contextIdentifier,
          port: port
        )
        try participant.flush()
        try remove(participant: participant)
      }
    }
  }

  public func shouldPropagate(eventSource: EventSource) -> Bool {
    switch eventSource {
    case .joinTimer:
      fallthrough
    case .peer:
      fallthrough
    case .peerChanged:
      fallthrough
    case .application:
      return true // FIXME: check whether we should propagate application withdrawals?
    case .internal:
      fallthrough // don't need to propagate this because application calls all participants
    case .map:
      fallthrough
    case .leaveAll:
      fallthrough
    case .leaveTimer:
      fallthrough
    case .leaveAllTimer:
      fallthrough
    case .periodicTimer:
      return false // don't recursively call ourselves, and let each participant handle leave timers
    }
  }

  private func _propagateJoinIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) throws {
    guard shouldPropagate(eventSource: eventSource) else { return }
    try apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      try participant.join(
        attributeType: attributeType,
        attributeSubtype: attributeSubtype,
        attributeValue: attributeValue,
        isNew: isNew,
        eventSource: .map
      )
    }
  }

  public func joinIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) async throws {
    precondition(!(attributeValue is AnyValue))
    do {
      if let observer = self as? any BaseApplicationEventObserver<P> {
        try await observer.onJoinIndication(
          contextIdentifier: contextIdentifier,
          port: port,
          attributeType: attributeType,
          attributeSubtype: attributeSubtype,
          attributeValue: attributeValue,
          isNew: isNew,
          eventSource: eventSource
        )
      }
    } catch MRPError.doNotPropagateAttribute {
      return
    }
    try _propagateJoinIndicated(
      contextIdentifier: contextIdentifier,
      port: port,
      attributeType: attributeType,
      attributeSubtype: attributeSubtype,
      attributeValue: attributeValue,
      isNew: isNew,
      eventSource: eventSource
    )
  }

  private func _propagateLeaveIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: EventSource
  ) throws {
    guard shouldPropagate(eventSource: eventSource) else { return }
    let participants = findParticipants(for: contextIdentifier)
    try apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      // 10.3 b): propagate a Leave to a port if and only if no registration for the
      // attribute now exists on any other port excluding it
      let isRegisteredElsewhere = participants.contains {
        $0.port != participant.port && $0.isRegisteredUnchecked(
          attributeType: attributeType,
          matching: .matchIndex(attributeValue),
          isolation: self
        )
      }
      guard !isRegisteredElsewhere else { return }
      try participant.leave(
        attributeType: attributeType,
        attributeSubtype: attributeSubtype,
        attributeValue: attributeValue,
        eventSource: .map
      )
    }
  }

  // Administratively register an attribute on a port (Registration Fixed, 10.7.2), e.g.
  // realizing a Static VLAN Registration Entry (8.8.2), and propagate it via MAP (10.3 a)
  // to the other ports. onJoinIndication is not invoked: the registration is already
  // present administratively (e.g. the kernel bridge VLAN), so only propagation is needed.
  func administrativelyRegister(
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool = false,
    on port: P,
    for contextIdentifier: MAPContextIdentifier
  ) throws {
    let participant = try findParticipant(for: contextIdentifier, port: port)
    try participant.administrativelyRegister(
      attributeType: attributeType,
      attributeValue: attributeValue
    )
    try _propagateJoinIndicated(
      contextIdentifier: contextIdentifier,
      port: port,
      attributeType: attributeType,
      attributeSubtype: nil,
      attributeValue: attributeValue,
      isNew: isNew,
      eventSource: .application
    )
  }

  // Clear an administrative registration and withdraw it via MAP (10.3 b). Any underlying
  // dynamic registration is revealed and times out normally (and, being still registered,
  // suppresses the propagated withdrawal until it does).
  func administrativelyDeregister(
    attributeType: AttributeType,
    attributeValue: some Value,
    from port: P,
    for contextIdentifier: MAPContextIdentifier
  ) throws {
    let participant = try findParticipant(for: contextIdentifier, port: port)
    try participant.administrativelyDeregister(
      attributeType: attributeType,
      attributeValue: attributeValue
    )
    try _propagateLeaveIndicated(
      contextIdentifier: contextIdentifier,
      port: port,
      attributeType: attributeType,
      attributeSubtype: nil,
      attributeValue: attributeValue,
      eventSource: .application
    )
  }

  public func leaveIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: EventSource
  ) async throws {
    precondition(!(attributeValue is AnyValue))
    do {
      if let observer = self as? any BaseApplicationEventObserver<P> {
        try await observer.onLeaveIndication(
          contextIdentifier: contextIdentifier,
          port: port,
          attributeType: attributeType,
          attributeSubtype: attributeSubtype,
          attributeValue: attributeValue,
          eventSource: eventSource
        )
      }
    } catch MRPError.doNotPropagateAttribute {
      return
    }
    try _propagateLeaveIndicated(
      contextIdentifier: contextIdentifier,
      port: port,
      attributeType: attributeType,
      attributeSubtype: attributeSubtype,
      attributeValue: attributeValue,
      eventSource: eventSource
    )
  }
}
