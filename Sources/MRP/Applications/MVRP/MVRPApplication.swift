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

import IEEE802
import Logging
import Synchronization
#if canImport(FlyingFox)
import FlyingFox
#endif

public let MVRPEtherType: UInt16 = 0x88F5

protocol MVRPAwareBridge<P>: Bridge where P: Port {
  // allow use of platform MVRP applicant (e.g. in-kernel Linux MVRP implementation)
  var hasLocalMVRPApplicant: Bool { get }

  func register(vlan: VLAN, on port: P) async throws
  func deregister(vlan: VLAN, from port: P) async throws
}

public final class MVRPApplication<P: Port>: BaseApplication, BaseApplicationEventObserver,
  BaseApplicationContextObserver, CustomStringConvertible,
  Sendable where P == P
{
  // for now, we only operate in the Base Spanning Tree Context
  public var nonBaseContextsSupported: Bool { false }

  public var validAttributeTypes: ClosedRange<AttributeType> {
    MVRPAttributeType.validAttributeTypes
  }

  // 10.12.1.3 MVRP application address
  public var groupAddress: EUI48 { CustomerBridgeMRPGroupAddress }

  // 10.12.1.4 MVRP application EtherType
  public var etherType: UInt16 { MVRPEtherType }

  // 10.12.1.5 MVRP ProtocolVersion
  public var protocolVersion: ProtocolVersion { 0 }

  public var hasAttributeListLength: Bool { false }

  let _controller: Weak<MRPController<P>>

  public var controller: MRPController<P>? { _controller.object }

  let _participants =
    Mutex<[MAPContextIdentifier: Set<Participant<MVRPApplication<P>>>]>([:])
  let _logger: Logger
  let _vlanExclusions: Set<VLAN>

  public init(controller: MRPController<P>, vlanExclusions: Set<VLAN> = []) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    _vlanExclusions = vlanExclusions
    try await controller.register(application: self)
  }

  public var description: String {
    let participants: String = _participants.withLock { String(describing: $0) }
    return "MVRPApplication(controller: \(controller!), vlanExclusions: \(_vlanExclusions), participants: \(participants))"
  }

  public var name: String { "MVRP" }

  public func deserialize(
    attributeOfType attributeType: AttributeType,
    from deserializationContext: inout DeserializationContext
  ) throws -> any Value {
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      return try VLAN(deserializationContext: &deserializationContext)
    }
  }

  public func makeNullValue(for attributeType: AttributeType) throws -> any Value {
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      return VLAN()
    }
  }

  public func hasAttributeSubtype(for: AttributeType) -> Bool {
    false
  }

  public func administrativeControl(for attributeType: AttributeType) throws
    -> AdministrativeControl
  {
    .normalParticipant
  }

  // On receipt of an ES_REGISTER_VLAN_MEMBER service primitive, the MVRP
  // Participant issues a MAD_Join.request service primitive (10.2, 10.3). The
  // attribute_type parameter of the request carries the value of the VID
  // Vector Attribute Type (11.2.3.1.6) and the attribute_value parameter
  // carries the value of the VID parameter carried in the
  // ES_REGISTER_VLAN_MEMBER primitive.
  public func register(vlanMember: VLAN) async throws {
    try await join(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: vlanMember,
      isNew: false,
      for: MAPBaseSpanningTreeContext
    )
  }

  // On receipt of an ES_DEREGISTER_VLAN_MEMBER service primitive, the MVRP
  // Participant issues a MAD_Leave.request service primitive (10.2, 10.3). The
  // attribute_type parameter of the request carries the value of the VID
  // Vector Attribute Type (11.2.3.1.6) and the attribute_value parameter
  // carries the value of the VID parameter carried in the
  // ES_DEREGISTER_VLAN_MEMBER primitive.
  public func deregister(vlanMember: VLAN) async throws {
    try await leave(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: vlanMember,
      for: MAPBaseSpanningTreeContext
    )
  }
}

extension MVRPApplication {
  // On receipt of a MAD_Join.indication whose attribute_type is equal to the
  // value of the VID Vector Attribute Type (11.2.3.1.6), the MVRP application
  // element indicates the reception Port as Registered in the Port Map of the
  // Dynamic VLAN Registration Entry for the VID indicated by the
  // attribute_value parameter. If no such entry exists, there is sufficient
  // room in the FDB, and the VID is within the range of values supported by
  // the implementation (see 9.6), then an entry is created. If not, then the
  // indication is not propagated and the registration fails.
  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MVRPAwareBridge<P> else { return }
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      let vlan = (attributeValue as! VLAN)
      guard !_vlanExclusions.contains(vlan) else { throw MRPError.doNotPropagateAttribute }
      guard !bridge.hasLocalMVRPApplicant || eventSource != .local
      else { throw MRPError.doNotPropagateAttribute }
      _logger
        .info(
          "MVRP: join indication from port \(port) VID \(vlan.vid) isNew \(isNew) source \(eventSource)"
        )
      // TODO: flush FDB entries following a topology change, if isNew is true
      try await bridge.register(vlan: vlan, on: port)
    }
  }

  // On receipt of a MAD_Leave.indication whose attribute_type is equal to the
  // value of the VID Vector Attribute Type (11.2.3.1.6), the MVRP application
  // element indicates the reception Port as not Registered in the Port Map of
  // the Dynamic VLAN Registration Entry for the VID indicated by the
  // attribute_value parameter. If no such entry exists, the indication is
  // ignored.
  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: EventSource
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MVRPAwareBridge<P> else { return }
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      let vlan = (attributeValue as! VLAN)
      guard !_vlanExclusions.contains(vlan) else { throw MRPError.doNotPropagateAttribute }
      guard !bridge.hasLocalMVRPApplicant || eventSource != .local
      else { throw MRPError.doNotPropagateAttribute }
      _logger.info("MVRP: leave indication from port \(port) VID \(vlan.vid) source \(eventSource)")
      try await bridge.deregister(vlan: vlan, from: port)
    }
  }
}

extension MVRPApplication {
  func onContextAdded(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    guard let bridge = controller?.bridge as? any MVRPAwareBridge<P>,
          !bridge.hasLocalMVRPApplicant else { return }
    try await join(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: VLAN(contextIdentifier: contextIdentifier),
      isNew: true,
      for: MAPBaseSpanningTreeContext
    )
  }

  func onContextUpdated(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {}

  func onContextRemoved(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {
    guard let bridge = controller?.bridge as? any MVRPAwareBridge<P>,
          !bridge.hasLocalMVRPApplicant else { return }
    Task {
      try await leave(
        attributeType: MVRPAttributeType.vid.rawValue,
        attributeValue: VLAN(contextIdentifier: contextIdentifier),
        for: MAPBaseSpanningTreeContext
      )
    }
  }
}

#if canImport(FlyingFox)
extension MVRPApplication: RestApiApplication {
  func registerRestApiHandlers(for httpServer: HTTPServer) async throws {
    let mvrpHandler = MVRPHandler(application: self)

    await httpServer.appendRoute("GET /api/avb/mvrp", to: mvrpHandler)
    await httpServer.appendRoute("GET /api/avb/mvrp/*", to: mvrpHandler)
  }
}
#endif
