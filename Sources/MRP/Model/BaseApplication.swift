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

protocol BaseApplicationDelegate<P>: Sendable {
  associatedtype P: Port

  func onContextAdded(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws
  func onContextUpdated(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws
  func onContextRemoved(contextIdentifier: MAPContextIdentifier, with context: MAPContext<P>) throws

  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool,
    flags: ParticipantEventFlags
  ) async throws
  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    flags: ParticipantEventFlags
  ) async throws
}

protocol BaseApplication: Application where P == P {
  typealias MAPParticipantDictionary = [MAPContextIdentifier: Set<Participant<Self>>]

  var _mad: Weak<Controller<P>> { get }
  var _participants: ManagedCriticalState<MAPParticipantDictionary> { get }
  var _delegate: (any BaseApplicationDelegate<P>)? { get }

  var _contextsSupported: Bool { get }
}

extension BaseApplication {
  var mad: Controller<P>? { _mad.object }

  public func add(participant: Participant<Self>) throws {
    precondition(_contextsSupported || participant.contextIdentifier == MAPBaseSpanningTreeContext)
    _participants.withCriticalRegion {
      if let index = $0.index(forKey: participant.contextIdentifier) {
        $0.values[index].insert(participant)
      } else {
        $0[participant.contextIdentifier] = Set([participant])
      }
    }
  }

  public func remove(
    participant: Participant<Self>
  ) throws {
    precondition(_contextsSupported || participant.contextIdentifier == MAPBaseSpanningTreeContext)
    _participants.withCriticalRegion {
      $0[participant.contextIdentifier]?.remove(participant)
    }
  }

  @discardableResult
  public func apply<T>(
    for contextIdentifier: MAPContextIdentifier? = nil,
    _ block: AsyncApplyFunction<T>
  ) async rethrows -> [T] {
    var participants: Set<Participant<Self>>?
    _participants.withCriticalRegion {
      if let contextIdentifier {
        participants = $0[contextIdentifier]
      } else {
        participants = Set($0.flatMap { Array($1) })
      }
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
    var participants: Set<Participant<Self>>?
    _participants.withCriticalRegion {
      if let contextIdentifier {
        participants = $0[contextIdentifier]
      } else {
        participants = Set($0.flatMap { Array($1) })
      }
    }
    var ret = [T]()
    if let participants {
      for participant in participants {
        try ret.append(block(participant))
      }
    }
    return ret
  }

  public func didAdd(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    guard _contextsSupported || contextIdentifier == MAPBaseSpanningTreeContext else { return }
    try _delegate?.onContextAdded(contextIdentifier: contextIdentifier, with: context)
    for port in context {
      guard (try? findParticipant(for: contextIdentifier, port: port)) == nil
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
  }

  public func didUpdate(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {
    guard _contextsSupported || contextIdentifier == MAPBaseSpanningTreeContext else { return }
    try _delegate?.onContextUpdated(contextIdentifier: contextIdentifier, with: context)
    for port in context {
      let participant = try findParticipant(
        for: contextIdentifier,
        port: port
      )
      Task { try await participant.redeclare() }
    }
  }

  public func didRemove(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {
    guard _contextsSupported || contextIdentifier == MAPBaseSpanningTreeContext else { return }
    try _delegate?.onContextRemoved(contextIdentifier: contextIdentifier, with: context)
    for port in context {
      let participant = try findParticipant(
        for: contextIdentifier,
        port: port
      )
      Task { try await participant.flush() }
      try remove(participant: participant)
    }
  }

  public func joinIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool,
    flags: ParticipantEventFlags
  ) async throws {
    try await _delegate?.onJoinIndication(
      contextIdentifier: contextIdentifier,
      port: port,
      attributeType: attributeType,
      attributeValue: attributeValue,
      isNew: isNew,
      flags: flags
    )
    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      try await participant.join(
        attributeType: attributeType,
        attributeValue: attributeValue,
        isNew: isNew
      )
    }
  }

  public func leaveIndicated(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    flags: ParticipantEventFlags
  ) async throws {
    try await _delegate?.onLeaveIndication(
      contextIdentifier: contextIdentifier,
      port: port,
      attributeType: attributeType,
      attributeValue: attributeValue,
      flags: flags
    )
    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      try await participant.leave(
        attributeType: attributeType,
        attributeValue: attributeValue
      )
    }
  }
}
