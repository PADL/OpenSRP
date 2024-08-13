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

import Locking
import Logging

public let MSRPEtherType: UInt16 = 0x22EA

enum MSRPPortMediaType {
  case accessControlPort
  case nonDMNSharedMediumPort
}

enum MSRPDirection {
  case talker
  case listener
}

enum MSRPDeclarationType {
  case talkerAdvertise
  case talkerFailed
  case listenerAskingFailed
  case listenerReady
  case listenerReadyFailed
}

struct MSRPPortParameters {}

protocol MSRPAwareBridge<P>: Bridge where P: Port {}

public final class MSRPApplication<P: Port>: BaseApplication, BaseApplicationDelegate,
  CustomStringConvertible,
  Sendable where P == P
{
  var _delegate: (any BaseApplicationDelegate<P>)? { self }

  // for now, we only operate in the Base Spanning Tree Context
  public var nonBaseContextsSupported: Bool { false }

  public var validAttributeTypes: ClosedRange<AttributeType> {
    MSRPAttributeType.validAttributeTypes
  }

  public var groupAddress: EUI48 { IndividualLANScopeGroupAddress }

  public var etherType: UInt16 { MSRPEtherType }

  public var protocolVersion: ProtocolVersion { 0 }

  public var hasAttributeListLength: Bool { true }

  let _controller: Weak<MRPController<P>>

  public var controller: MRPController<P>? { _controller.object }

  let _participants =
    ManagedCriticalState<[MAPContextIdentifier: Set<Participant<MSRPApplication<P>>>]>([:])
  let _logger: Logger

  public init(controller: MRPController<P>) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    try await controller.register(application: self)
  }

  public var description: String {
    "MSRPApplication(controller: \(controller!), participants: \(_participants.criticalState))"
  }

  public func deserialize(
    attributeOfType attributeType: AttributeType,
    from deserializationContext: inout DeserializationContext
  ) throws -> any Value {
    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    fatalError()
  }

  public func makeValue(for attributeType: AttributeType, at index: Int) throws -> any Value {
    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    fatalError()
  }

  public func hasApplicationEvents(for: AttributeType) -> Bool {
    false
  }

  public func mapApplicationEvent(for context: ApplicationEventContext) throws -> ApplicationEvent {
    throw MRPError.unknownAttributeType
  }

  public func administrativeControl(for attributeType: AttributeType) throws
    -> AdministrativeControl
  {
    .normalParticipant
  }
}

extension MSRPApplication {
  // these are not called because only the base spanning tree context is supported
  // at present
  func onContextAdded(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {}

  func onContextUpdated(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {}

  func onContextRemoved(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {}

  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: ParticipantEventSource,
    applicationEvent: ApplicationEvent?
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MSRPAwareBridge<P> else { return }
  }

  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeValue: some Value,
    eventSource: ParticipantEventSource,
    applicationEvent: ApplicationEvent?
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MSRPAwareBridge<P> else { return }
  }
}
