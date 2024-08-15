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

protocol MSRPAwareBridge<P>: Bridge where P: Port {
  func adjustCreditBasedShaper(
    portID: P.ID,
    priority: SRclassPriority,
    idleSlope: Int,
    sendSlope: Int,
    hiCredit: Int,
    loCredit: Int
  ) async throws
}

private extension Port {
  var systemID: UInt64 {
    UInt64(eui48: macAddress)
  }
}

public struct MSRPPortState<P: Port>: Sendable {
  let mediaType: MSRPPortMediaType
  var enabled: Bool
  var tcMaxLatency: [MSRPTrafficClass: MSRPPortLatency]
  let streamEpoch: UInt32
  var srpDomainBoundaryPort: [SRclassID: Bool]
  // Table 6-5—Default SRP domain boundary port priority regeneration override values
  var srClassPriorityMap: [SRclassID: SRclassPriority] = [
    .A: SRclassPriority(rawValue: 3)!,
    .B: SRclassPriority(rawValue: 2)!,
  ]
  let neighborProtocolVersion: MSRPProtocolVersion
  let talkerPruning: Bool
  let talkerVlanPruning: Bool

  func reverseMapSrClassPriority(priority: SRclassPriority) -> SRclassID? {
    srClassPriorityMap.first(where: {
      $0.value == priority
    })?.key
  }

  var streamAge: UInt32 {
    guard let time = try? P.timeSinceEpoch() else {
      return 0
    }
    return time - streamEpoch
  }

  init(msrp: MSRPApplication<P>, port: P) throws {
    mediaType = .accessControlPort
    enabled = port.isEnabled
    tcMaxLatency = [:]
    streamEpoch = try P.timeSinceEpoch()
    srpDomainBoundaryPort = .init(uniqueKeysWithValues: SRclassID.allCases.map { ($0, false) })
    neighborProtocolVersion = .v0
    talkerPruning = false
    talkerVlanPruning = false
  }
}

public final class MSRPApplication<P: Port>: BaseApplication, BaseApplicationDelegate,
  CustomStringConvertible,
  @unchecked Sendable where P == P
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

  let _talkerPruning: Bool
  let _maxFanInPorts: Int
  let _latencyMaxFrameSize: UInt16
  let _srPVid: VLAN
  let _maxSRClasses: SRclassID
  var _ports = ManagedCriticalState<[P.ID: MSRPPortState<P>]>([:])
  let _mmrp: MMRPApplication<P>?

  public init(
    controller: MRPController<P>,
    talkerPruning: Bool = false,
    maxFanInPorts: Int = 0,
    latencyMaxFrameSize: UInt16 = 2000,
    srPVid: VLAN = VLAN(id: 2),
    maxSRClasses: SRclassID = .B
  ) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    _talkerPruning = talkerPruning
    _maxFanInPorts = maxFanInPorts
    _latencyMaxFrameSize = latencyMaxFrameSize
    _srPVid = srPVid
    _maxSRClasses = maxSRClasses
    _mmrp = try? await controller.application(for: MMRPEtherType)
    try await controller.register(application: self)
  }

  @discardableResult
  fileprivate func withPortState<T>(
    port: P,
    body: (_: inout MSRPPortState<P>) throws -> T
  ) rethrows -> T {
    try _ports.withCriticalRegion {
      if let index = $0.index(forKey: port.id) {
        return try body(&$0.values[index])
      } else {
        var newPortState = try MSRPPortState(msrp: self, port: port)
        let ret = try body(&newPortState)
        $0[port.id] = newPortState
        return ret
      }
    }
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
    switch attributeType {
    case .talkerAdvertise:
      return try MSRPTalkerAdvertiseValue(deserializationContext: &deserializationContext)
    case .talkerFailed:
      return try MSRPTalkerFailedValue(deserializationContext: &deserializationContext)
    case .listener:
      return try MSRPListenerValue(deserializationContext: &deserializationContext)
    case .domain:
      return try MSRPDomainValue(deserializationContext: &deserializationContext)
    }
  }

  public func makeNullValue(for attributeType: AttributeType) throws -> any Value {
    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .talkerAdvertise:
      return try MSRPTalkerAdvertiseValue(index: 0)
    case .talkerFailed:
      return try MSRPTalkerFailedValue(index: 0)
    case .listener:
      return try MSRPListenerValue(index: 0)
    case .domain:
      return try MSRPDomainValue(index: 0)
    }
  }

  public func hasAttributeSubtype(for attributeType: AttributeType) -> Bool {
    attributeType == MSRPAttributeType.listener.rawValue
  }

  public func administrativeControl(for attributeType: AttributeType) throws
    -> AdministrativeControl
  {
    .normalParticipant
  }

  private func declarationType(for streamID: MSRPStreamID) throws -> MSRPDeclarationType {
    throw MRPError.invalidMSRPDeclarationType
  }

  // If an MSRP message is received from a Port with an event value specifying
  // the JoinIn or JoinMt message, and if the StreamID (35.2.2.8.2,
  // 35.2.2.10.2), and Direction (35.2.1.2) all match those of an attribute
  // already registered on that Port, and the Attribute Type (35.2.2.4) or
  // FourPackedEvent (35.2.2.7.2) has changed, then the Bridge should behave as
  // though an rLv! event (with immediate leavetimer expiration in the
  // Registrar state table) was generated for the MAD in the Received MSRP
  // Attribute Declarations before the rJoinIn! or rJoinMt! event for the
  // attribute in the received message is processed
  public func preApplicantEventHandler(
    context: ApplicantEventContext<MSRPApplication>
  ) async throws {
    guard context.event == .rJoinIn || context.event == .rJoinMt else { return }

    let contextAttributeType = MSRPAttributeType(rawValue: context.attributeType)!
    guard let contextDirection = contextAttributeType.direction else { return }

    let contextStreamID = (context.attributeValue as! MSRPStreamIDRepresentable).streamID

    try await context.participant.leaveNow { attributeType, attributeSubtype, attributeValue in
      let attributeType = MSRPAttributeType(rawValue: attributeType)!
      guard let direction = attributeType.direction else { return false }
      let streamID = (attributeValue as! MSRPStreamIDRepresentable).streamID

      return contextStreamID == streamID && contextDirection == direction &&
        (contextAttributeType != attributeType || context.attributeSubtype != attributeSubtype)
    }
  }

  public func postApplicantEventHandler(context: ApplicantEventContext<MSRPApplication>) {}

  // On receipt of a REGISTER_STREAM.request the MSRP Participant shall issue a
  // MAD_Join.request service primitive (10.2, 10.3). The attribute_type (10.2)
  // parameter of the request shall carry the appropriate Talker Attribute Type
  // (35.2.2.4), depending on the Declaration Type and neighborProtocolVersion.
  // The attribute_value (10.2) parameter shall carry the values from the
  // REGISTER_STREAM.request primitive.
  public func registerStream(
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank,
    accumulatedLatency: UInt32,
    failureInformation: MSRPFailure? = nil
  ) async throws {
    let attributeValue: any Value

    switch declarationType {
    case .talkerAdvertise:
      guard failureInformation == nil else {
        throw MRPError.invalidMSRPDeclarationType
      }
      attributeValue = MSRPTalkerAdvertiseValue(
        streamID: streamID,
        dataFrameParameters: dataFrameParameters,
        tSpec: tSpec,
        priorityAndRank: priorityAndRank,
        accumulatedLatency: accumulatedLatency
      )
    case .talkerFailed:
      guard let failureInformation else {
        throw MRPError.invalidMSRPDeclarationType
      }
      attributeValue = MSRPTalkerFailedValue(
        streamID: streamID,
        dataFrameParameters: dataFrameParameters,
        tSpec: tSpec,
        priorityAndRank: priorityAndRank,
        accumulatedLatency: accumulatedLatency,
        systemID: failureInformation.systemID,
        failureCode: failureInformation.failureCode
      )
    case .listenerAskingFailed:
      fallthrough
    case .listenerReady:
      fallthrough
    case .listenerReadyFailed:
      throw MRPError.invalidMSRPDeclarationType
    }

    try await join(
      attributeType: (
        failureInformation != nil ? MSRPAttributeType.talkerFailed : MSRPAttributeType
          .talkerAdvertise
      ).rawValue,
      attributeValue: attributeValue,
      isNew: true,
      for: MAPBaseSpanningTreeContext
    )
  }

  // On receipt of a DEREGISTER_STREAM.request the MSRP Participant shall issue
  // a MAD_Leave.request service primitive (10.2, 10.3) with the attribute_type
  // set to the Declaration Type currently associated with the StreamID. The
  // attribute_value parameter shall carry the StreamID and other values that
  // were in the associated REGISTER_STREAM.request primitive.
  public func deregisterStream(
    streamID: MSRPStreamID
  ) async throws {
    try await leave(
      attributeType: declarationType(for: streamID).attributeType.rawValue,
      attributeValue: MSRPListenerValue(streamID: streamID),
      for: MAPBaseSpanningTreeContext
    )
  }

  // On receipt of a REGISTER_ATTACH.request the MSRP Participant shall issue a
  // MAD_Join.request service primitive (10.2, 10.3). The attribute_type
  // parameter of the request shall carry the appropriate Listener Attribute
  // Type (35.2.2.4), depending on neighborProtocolVersion. The attribute_value
  // shall contain the StreamID and the Declaration Type.
  public func registerAttach(
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType
  ) async throws {
    try await join(
      attributeType: declarationType.attributeType.rawValue,
      attributeValue: MSRPListenerValue(streamID: streamID),
      isNew: false,
      for: MAPBaseSpanningTreeContext
    )
  }

  // On receipt of a DEREGISTER_ATTACH.request the MSRP Participant shall issue
  // a MAD_Leave.request service primitive (10.2, 10.3) with the attribute_type
  // set to the appropriate Listener Attribute Type (35.2.2.4). The
  // attribute_value parameter shall carry the StreamID and the Declaration
  // Type currently associated with the StreamID.
  public func deregisterAttach(
    streamID: MSRPStreamID
  ) async throws {
    try await leave(
      attributeType: declarationType(for: streamID).attributeType.rawValue,
      attributeValue: MSRPListenerValue(streamID: streamID),
      for: MAPBaseSpanningTreeContext
    )
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

  private func _shouldPruneTalkerDeclaration(
    port: P,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank,
    accumulatedLatency: UInt32,
    isNew: Bool,
    eventSource: ParticipantEventSource
  ) async -> Bool {
    if _talkerPruning || portState.talkerPruning {
      // FIXME: we need to examine unicast addresses too
      if _isMulticast(macAddress: dataFrameParameters.destinationAddress),
         let mmrpParticipant = try? _mmrp?.findParticipant(port: port),
         await mmrpParticipant.findAttribute(
           attributeType: MMRPAttributeType.mac.rawValue,
           matching: .matchEqual(MMRPMACValue(macAddress: dataFrameParameters.destinationAddress))
         ) == nil
      {
        return true
      }
    }
    if portState.talkerVlanPruning {
      guard port.vlans.contains(dataFrameParameters.vlanIdentifier) else { return true }
    }

    return false
  }

  private func _canPropagateTalkerAdvertise(
    port: P,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank,
    accumulatedLatency: UInt32,
    isNew: Bool,
    eventSource: ParticipantEventSource
  ) -> TSNFailureCode? {
    // analyse available bandwidth to determine if outbound port has enough resources
    // verify msrpMaxFanInports

    guard let srClassID = portState
      .reverseMapSrClassPriority(priority: priorityAndRank.dataFramePriority),
      portState.srpDomainBoundaryPort[srClassID] == false
    else {
      return .egressPortIsNotAvbCapable
    }

    // stream rank (make streams comparable?) by comparing Rank, then streamAge, then streamID
    // determine totalFrameSize for a port
    return nil
  }

  // On receipt of a MAD_Join.indication service primitive (10.2, 10.3) with an
  // attribute_type of Talker Advertise, Talker Failed, or Talker Enhanced
  // (35.2.2.4), the MSRP application shall issue a REGISTER_STREAM.indication
  // to the Listener application entity. The REGISTER_STREAM.indication shall
  // carry the values from the attribute_value parameter.
  private func _onRegisterStreamIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank,
    accumulatedLatency: UInt32,
    failureInformation: MSRPFailure?,
    isNew: Bool,
    eventSource: ParticipantEventSource
  ) async throws {
    var portState: MSRPPortState<P>!

    withPortState(port: port) {
      portState = $0
    }

    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }

      guard await !_shouldPruneTalkerDeclaration(
        port: participant.port,
        portState: portState,
        streamID: streamID,
        declarationType: declarationType,
        dataFrameParameters: dataFrameParameters,
        tSpec: tSpec,
        priorityAndRank: priorityAndRank,
        accumulatedLatency: accumulatedLatency,
        isNew: isNew,
        eventSource: eventSource
      ) else {
        return
      }

      let accumulatedLatency = accumulatedLatency + UInt32(port.latency)

      if declarationType == .talkerAdvertise {
        if let tsnFailureCode = _canPropagateTalkerAdvertise(
          port: participant.port,
          portState: portState,
          streamID: streamID,
          declarationType: declarationType,
          dataFrameParameters: dataFrameParameters,
          tSpec: tSpec,
          priorityAndRank: priorityAndRank,
          accumulatedLatency: accumulatedLatency,
          isNew: isNew,
          eventSource: eventSource
        ) {
          let talkerFailed = MSRPTalkerFailedValue(
            streamID: streamID,
            dataFrameParameters: dataFrameParameters,
            tSpec: tSpec,
            priorityAndRank: priorityAndRank,
            accumulatedLatency: accumulatedLatency,
            systemID: port.systemID,
            failureCode: tsnFailureCode
          )
          try await participant.join(
            attributeType: MSRPAttributeType.talkerFailed.rawValue,
            attributeValue: talkerFailed,
            isNew: true,
            eventSource: .map
          )
        } else {
          let talkerAdvertise = MSRPTalkerAdvertiseValue(
            streamID: streamID,
            dataFrameParameters: dataFrameParameters,
            tSpec: tSpec,
            priorityAndRank: priorityAndRank,
            accumulatedLatency: accumulatedLatency
          )
          try await participant.join(
            attributeType: MSRPAttributeType.talkerFailed.rawValue,
            attributeValue: talkerAdvertise,
            isNew: false,
            eventSource: .map
          )
        }
      } else {
        precondition(declarationType == .talkerFailed)
        let talkerFailed = MSRPTalkerFailedValue(
          streamID: streamID,
          dataFrameParameters: dataFrameParameters,
          tSpec: tSpec,
          priorityAndRank: priorityAndRank,
          accumulatedLatency: accumulatedLatency,
          systemID: failureInformation!.systemID,
          failureCode: failureInformation!.failureCode
        )
        try await participant.join(
          attributeType: MSRPAttributeType.talkerFailed.rawValue,
          attributeValue: talkerFailed,
          isNew: false,
          eventSource: .map
        )
      }
    }
    throw MRPError.doNotPropagateAttribute // advise caller we have performed MAP ourselves
  }

  private func _mergeListener(
    declarationType firstDeclarationType: MSRPDeclarationType,
    with secondDeclarationType: MSRPDeclarationType?
  ) -> MSRPDeclarationType {
    if firstDeclarationType == .listenerReady {
      if secondDeclarationType == nil || secondDeclarationType == .listenerReady {
        return .listenerReady
      } else if secondDeclarationType == .listenerReadyFailed || secondDeclarationType ==
        .listenerAskingFailed
      {
        return .listenerReadyFailed
      }
    } else if firstDeclarationType == .listenerAskingFailed {
      if secondDeclarationType == .listenerReady || secondDeclarationType == .listenerReadyFailed {
        return .listenerReadyFailed
      } else if secondDeclarationType == nil || secondDeclarationType == .listenerAskingFailed {
        return .listenerAskingFailed
      }
    }
    return .listenerReadyFailed
  }

  private func _findTalkerRegistration(
    for streamID: MSRPStreamID,
    participant: Participant<MSRPApplication>
  ) async -> Bool? {
    if let _ = await participant.findAttribute(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchIndex(MSRPTalkerAdvertiseValue(streamID: streamID))
    ) {
      true
    } else if let _ = await participant.findAttribute(
      attributeType: MSRPAttributeType.talkerFailed.rawValue,
      matching: .matchIndex(MSRPTalkerFailedValue(streamID: streamID))
    ) {
      false
    } else {
      nil
    }
  }

  // On receipt of a MAD_Join.indication service primitive (10.2, 10.3) with an
  // attribute_type of Listener (35.2.2.4), the MSRP application shall issue a
  // REGISTER_ATTACH.indication to the Talker application entity. The
  // REGISTER_ATTACH.indication shall carry the values from the attribute_value
  // parameter.
  private func _onRegisterAttachIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    isNew: Bool,
    eventSource: ParticipantEventSource
  ) async throws {
    try await apply(for: contextIdentifier) { participant in
      if participant.port != port, let talkerRegistration = await _findTalkerRegistration(
        for: streamID,
        participant: participant
      ) {
        let mergedDeclarationType: MSRPDeclarationType

        if talkerRegistration {
          let portDeclarationType: MSRPDeclarationType? = if let portDeclaration = await participant
            .findAttribute(
              attributeType: declarationType.attributeType.rawValue,
              matching: .matchAnyIndex(streamID) // this will match any kind of talker attribute
            )
          {
            try? MSRPDeclarationType(attributeSubtype: portDeclaration.0)
          } else {
            nil
          }

          mergedDeclarationType = _mergeListener(
            declarationType: declarationType,
            with: portDeclarationType
          )
        } else {
          mergedDeclarationType = .listenerAskingFailed
        }

        try await participant.join(
          attributeType: MSRPAttributeType.listener.rawValue,
          attributeSubtype: mergedDeclarationType.attributeSubtype?.rawValue,
          attributeValue: MSRPListenerValue(streamID: streamID),
          isNew: isNew,
          eventSource: .map
        )
      }
      // update dynamic reservation entries for _ALL_ ports (make this part of bridge aware
      // protocol)
    }

    throw MRPError.doNotPropagateAttribute // advise caller we have performed MAP ourselves
  }

  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: ParticipantEventSource
  ) async throws {
    // 35.2.4 (d) A MAD_Join.indication adds a new attribute to MAD (with isNew TRUE)
    guard isNew, eventSource != .map
    else { throw MRPError.doNotPropagateAttribute } // don't recursively invoke MAP

    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }

    switch attributeType {
    case .talkerAdvertise:
      let attributeValue = (attributeValue as! MSRPTalkerAdvertiseValue)
      try await _onRegisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: attributeValue.streamID,
        declarationType: .talkerAdvertise,
        dataFrameParameters: attributeValue.dataFrameParameters,
        tSpec: attributeValue.tSpec,
        priorityAndRank: attributeValue.priorityAndRank,
        accumulatedLatency: attributeValue.accumulatedLatency,
        failureInformation: nil,
        isNew: isNew,
        eventSource: eventSource
      )
    case .talkerFailed:
      let attributeValue = (attributeValue as! MSRPTalkerFailedValue)
      try await _onRegisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: attributeValue.streamID,
        declarationType: .talkerAdvertise,
        dataFrameParameters: attributeValue.dataFrameParameters,
        tSpec: attributeValue.tSpec,
        priorityAndRank: attributeValue.priorityAndRank,
        accumulatedLatency: attributeValue.accumulatedLatency,
        failureInformation: MSRPFailure(
          systemID: attributeValue.systemID,
          failureCode: attributeValue.failureCode
        ),
        isNew: isNew,
        eventSource: eventSource
      )
    case .listener:
      let attributeValue = (attributeValue as! MSRPListenerValue)
      guard let declarationType = try? MSRPDeclarationType(attributeSubtype: attributeSubtype)
      else { return }
      try await _onRegisterAttachIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: attributeValue.streamID,
        declarationType: declarationType,
        isNew: isNew,
        eventSource: eventSource
      )
    case .domain:
      let domain = (attributeValue as! MSRPDomainValue)
      withPortState(port: port) {
        $0.srpDomainBoundaryPort[domain.srClassID] = true
      }
      throw MRPError.doNotPropagateAttribute
    }
  }

  // On receipt of a MAD_Leave.indication service primitive (10.2, 10.3) with
  // an attribute_type of Talker Advertise, Talker Failed, or Talker Enhanced
  // (35.2.2.4), the MSRP application shall issue a
  // DEREGISTER_STREAM.indication to the Listener application entity.
  private func _onDeregisterStreamIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    eventSource: ParticipantEventSource
  ) async throws {
    // In the case where there is a Talker attribute and Listener attribute(s)
    // registered within a Bridge for a StreamID and a MAD_Leave.request is
    // received for the Talker attribute, the Bridge shall act as a proxy for the
    // Listener(s) and automatically generate a MAD_Leave.request back toward the
    // Talker for those Listener attributes. This is a special case of the
    // behavior described in 35.2.4.4.1.
    guard let talkerParticipant = try? findParticipant(port: port) else { return }
    try await apply { participant in
      guard let listenerAttribute = await participant.findAttribute(
        attributeType: MSRPAttributeType.listener.rawValue,
        matching: .matchEqual(MSRPListenerValue(streamID: streamID))
      ) else {
        return
      }
      try await talkerParticipant.leave(
        attributeType: MSRPAttributeType.listener.rawValue,
        attributeSubtype: listenerAttribute.0,
        attributeValue: listenerAttribute.1,
        eventSource: .map
      )
    }
    // FIXME: check normal propagation should still occur
  }

  // On receipt of a MAD_Leave.indication service primitive (10.2, 10.3) with
  // an attribute_type of Listener (35.2.2.4), the MSRP application shall issue
  // a DEREGISTER_ATTACH.indication to the Talker application entity.
  private func _onDeregisterAttachIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    eventSource: ParticipantEventSource
  ) async throws {
    // On receipt of a MAD_Leave.indication for a Listener Declaration, if the
    // StreamID of the Declaration matches a Stream that the Talker is
    // transmitting, then the Talker shall stop the transmission for this
    // Stream, if it is transmitting.
    // FIXME: check normal propagation should still occur
  }

  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: ParticipantEventSource
  ) async throws {
    guard eventSource != .map
    else { throw MRPError.doNotPropagateAttribute } // don't recursively invoke MAP

    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }

    switch attributeType {
    case .talkerAdvertise:
      try await _onDeregisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: (attributeValue as! MSRPTalkerAdvertiseValue).streamID,
        eventSource: eventSource
      )
    case .talkerFailed:
      try await _onDeregisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: (attributeValue as! MSRPTalkerFailedValue).streamID,
        eventSource: eventSource
      )
    case .listener:
      guard let declarationType = try? MSRPDeclarationType(attributeSubtype: attributeSubtype)
      else { return }
      try await _onDeregisterAttachIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: (attributeValue as! MSRPListenerValue).streamID,
        declarationType: declarationType,
        eventSource: eventSource
      )
    case .domain:
      let domain = (attributeValue as! MSRPDomainValue)
      withPortState(port: port) {
        $0.srpDomainBoundaryPort[domain.srClassID] = false
      }
      throw MRPError.doNotPropagateAttribute
    }
  }
}
