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

public let MMRPEtherType: UInt16 = 0x88F6

protocol MMRPAwareBridge<P>: Bridge where P: Port {
  func register(groupAddress: EUI48, on ports: Set<P>) async throws
  func deregister(groupAddress: EUI48, from ports: Set<P>) async throws

  func register(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue,
    on ports: Set<P>
  ) async throws
  func deregister(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue,
    from ports: Set<P>
  ) async throws
}

public final class MMRPApplication<P: Port>: BaseApplication, BaseApplicationEventDelegate,
  CustomStringConvertible,
  Sendable where P == P
{
  // for now, we only operate in the Base Spanning Tree Context
  public var nonBaseContextsSupported: Bool { false }

  public var validAttributeTypes: ClosedRange<AttributeType> {
    MMRPAttributeType.validAttributeTypes
  }

  // 10.12.1.3 MMRP application address
  public var groupAddress: EUI48 { CustomerBridgeMRPGroupAddress }

  // 10.12.1.4 MMRP application EtherType
  public var etherType: UInt16 { MMRPEtherType }

  // 10.12.1.5 MMRP ProtocolVersion
  public var protocolVersion: ProtocolVersion { 0 }

  public var hasAttributeListLength: Bool { false }

  let _controller: Weak<MRPController<P>>

  public var controller: MRPController<P>? { _controller.object }

  let _participants =
    ManagedCriticalState<[MAPContextIdentifier: Set<Participant<MMRPApplication<P>>>]>([:])
  let _logger: Logger

  public init(controller: MRPController<P>) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    try await controller.register(application: self)
  }

  public var description: String {
    "MMRPApplication(controller: \(controller!), participants: \(_participants.criticalState))"
  }

  public func deserialize(
    attributeOfType attributeType: AttributeType,
    from deserializationContext: inout DeserializationContext
  ) throws -> any Value {
    guard let attributeType = MMRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .mac:
      return try MMRPMACValue(deserializationContext: &deserializationContext)
    case .serviceRequirement:
      return try MMRPServiceRequirementValue(deserializationContext: &deserializationContext)
    }
  }

  public func makeNullValue(for attributeType: AttributeType) throws -> any Value {
    guard let attributeType = MMRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .mac:
      return MMRPMACValue(index: 0)
    case .serviceRequirement:
      return try MMRPServiceRequirementValue(index: 0)
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

  public func preApplicantEventHandler(
    context: EventContext<MMRPApplication>
  ) async throws {}
  public func postApplicantEventHandler(context: EventContext<MMRPApplication>) {}

  public func register(macAddress: EUI48) async throws {
    try await join(
      attributeType: MMRPAttributeType.mac.rawValue,
      attributeValue: MMRPMACValue(macAddress: macAddress),
      isNew: false,
      for: MAPBaseSpanningTreeContext
    )
  }

  public func deregister(macAddress: EUI48) async throws {
    try await leave(
      attributeType: MMRPAttributeType.mac.rawValue,
      attributeValue: MMRPMACValue(macAddress: macAddress),
      for: MAPBaseSpanningTreeContext
    )
  }

  public func register(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue
  ) async throws {
    try await join(
      attributeType: MMRPAttributeType.serviceRequirement.rawValue,
      attributeValue: requirementSpecification,
      isNew: false,
      for: MAPBaseSpanningTreeContext
    )
  }

  public func deregister(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue
  ) async throws {
    try await leave(
      attributeType: MMRPAttributeType.serviceRequirement.rawValue,
      attributeValue: requirementSpecification,
      for: MAPBaseSpanningTreeContext
    )
  }
}

extension MMRPApplication {
  // On receipt of a MAD_Join.indication, the MMRP application element
  // specifies the Port associated with the MMRP Participant as Forwarding in
  // the Port Map field of the MAC Address Registration Entry (8.8.4) for the
  // MAC address specification carried in the attribute_value parameter and the
  // VID associated with the MAP Context. If such a MAC Address Registration
  // Entry does not exist in the FDB, a new MAC Address Registration Entry is
  // created.
  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: ParticipantEventSource
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MMRPAwareBridge<P> else { return }
    let ports = await controller.context(for: contextIdentifier)
    guard let attributeType = MMRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .mac:
      let macAddress = (attributeValue as! MMRPMACValue).macAddress
      guard _isMulticast(macAddress: macAddress) else { throw MRPError.invalidAttributeValue }
      _logger
        .info(
          "MMRP join indication from port \(port) address \(_macAddressToString(macAddress)) isNew \(isNew) source \(eventSource)"
        )
      try await bridge.register(groupAddress: macAddress, on: ports)
    case .serviceRequirement:
      try await bridge.register(
        serviceRequirement: attributeValue as! MMRPServiceRequirementValue,
        on: ports
      )
    }
  }

  // On receipt of a MAD_Leave.indication, the MMRP application element
  // specifies the Port associated with the MMRP Participant as Filtering in
  // the Port Map field of the MAC Address Registration Entry (8.8.4) for the
  // MAC address specification carried in the attribute_value parameter and the
  // VID associated with the MAP Context. If such an FDB entry does not exist
  // in the FDB, then the indication is ignored. If setting that Port to
  // Filtering results in there being no Ports in the Port Map specified as
  // Forwarding (i.e., all MMRP members are deregistered), then that MAC
  // Address Registration Entry is removed from the FDB.
  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: ParticipantEventSource
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MMRPAwareBridge<P> else { return }
    let ports = await controller.context(for: contextIdentifier)
    guard let attributeType = MMRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .mac:
      let macAddress = (attributeValue as! MMRPMACValue).macAddress
      guard _isMulticast(macAddress: macAddress) else { throw MRPError.invalidAttributeValue }
      _logger
        .info(
          "MMRP leave indication from port \(port) address \(_macAddressToString(macAddress)) source \(eventSource)"
        )
      try await bridge.deregister(groupAddress: macAddress, from: ports)
    case .serviceRequirement:
      try await bridge.deregister(
        serviceRequirement: attributeValue as! MMRPServiceRequirementValue,
        from: ports
      )
    }
  }
}
