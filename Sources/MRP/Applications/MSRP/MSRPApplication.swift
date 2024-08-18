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

public protocol MSRPAwareBridge<P>: Bridge where P: AVBPort {
  func adjustCreditBasedShaper(
    portID: P.ID,
    srClass: SRclassID,
    idleSlope: Int,
    sendSlope: Int,
    hiCredit: Int,
    loCredit: Int
  ) async throws
}

private extension AVBPort {
  var systemID: UInt64 {
    UInt64(eui48: macAddress)
  }

  func reverseMapSrClassPriority(priority: SRclassPriority) async -> SRclassID? {
    try? await srClassPriorityMap.first(where: {
      $0.value == priority
    })?.key
  }
}

public struct MSRPPortState<P: AVBPort>: Sendable {
  var mediaType: MSRPPortMediaType { .accessControlPort }
  var msrpPortEnabledStatus: Bool
  var streamEpochs = [MSRPStreamID: UInt32]()
  var srpDomainBoundaryPort: [SRclassID: Bool]
  // Table 6-5—Default SRP domain boundary port priority regeneration override values
  var neighborProtocolVersion: MSRPProtocolVersion { .v0 }
  // TODO: make these configurable
  var talkerPruning: Bool { false }
  var talkerVlanPruning: Bool { false }

  mutating func register(streamID: MSRPStreamID) {
    streamEpochs[streamID] = (try? P.timeSinceEpoch()) ?? 0
  }

  mutating func deregister(streamID: MSRPStreamID) {
    streamEpochs[streamID] = nil
  }

  func getStreamAge(for streamID: MSRPStreamID) -> UInt32 {
    guard let epoch = streamEpochs[streamID],
          let time = try? P.timeSinceEpoch()
    else {
      return 0
    }

    return time - epoch
  }

  init(msrp: MSRPApplication<P>, port: P) throws {
    msrpPortEnabledStatus = port.isAvbCapable
    srpDomainBoundaryPort = .init(uniqueKeysWithValues: SRclassID.allCases.map { (
      $0,
      !port.isAvbCapable
    ) })
  }
}

public final class MSRPApplication<P: AVBPort>: BaseApplication, BaseApplicationEventObserver,
  ApplicationEventHandler, CustomStringConvertible, @unchecked Sendable where P == P
{
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
  let _maxSRClass: SRclassID
  var _ports = ManagedCriticalState<[P.ID: MSRPPortState<P>]>([:])
  let _mmrp: MMRPApplication<P>?

  public init(
    controller: MRPController<P>,
    talkerPruning: Bool = false,
    maxFanInPorts: Int = 0,
    latencyMaxFrameSize: UInt16 = 2000,
    srPVid: VLAN = VLAN(id: 2),
    maxSRClass: SRclassID = .B
  ) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    _talkerPruning = talkerPruning
    _maxFanInPorts = maxFanInPorts
    _latencyMaxFrameSize = latencyMaxFrameSize
    _srPVid = srPVid
    _maxSRClass = maxSRClass
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
        $0.values[index].msrpPortEnabledStatus = port.isAvbCapable
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
    context: EventContext<MSRPApplication>
  ) async throws {
    guard context.event == .rJoinIn || context.event == .rJoinMt else { return }

    let contextAttributeType = MSRPAttributeType(rawValue: context.attributeType)!
    guard let contextDirection = contextAttributeType.direction else { return }

    let contextStreamID = (context.attributeValue as! MSRPStreamIDRepresentable).streamID
    let contextAttributeSubtype = context.attributeSubtype

    try await context.participant.leaveNow { attributeType, attributeSubtype, attributeValue in
      let attributeType = MSRPAttributeType(rawValue: attributeType)!
      guard let direction = attributeType.direction else { return false }
      let streamID = (attributeValue as! MSRPStreamIDRepresentable).streamID

      return contextStreamID == streamID && contextDirection == direction &&
        (contextAttributeType != attributeType || contextAttributeSubtype != attributeSubtype)
    }
  }

  public func postApplicantEventHandler(context: EventContext<MSRPApplication>) {}

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

  private func _isFanInPortLimitReached() async -> Bool {
    if _maxFanInPorts == 0 {
      return false
    }

    var fanInCount = 0

    // calculate total number of ports with inbound reservations
    await apply { participant in
      if await participant.findAttribute(
        attributeType: MSRPAttributeType.listener.rawValue,
        matching: .matchAny
      ) != nil {
        fanInCount += 1
      }
    }

    return fanInCount <= _maxFanInPorts
  }

  private func _compareStreamImportance(
    port: P,
    portState: MSRPPortState<P>,
    _ lhs: MSRPTalkerAdvertiseValue,
    _ rhs: MSRPTalkerAdvertiseValue
  ) -> Bool {
    let lhsRank = lhs.priorityAndRank.rank ? 1 : 0
    let rhsRank = rhs.priorityAndRank.rank ? 1 : 0

    if lhsRank == rhsRank {
      let lhsStreamAge = portState.getStreamAge(for: lhs.streamID)
      let rhsStreamAge = portState.getStreamAge(for: rhs.streamID)

      if lhsStreamAge == rhsStreamAge {
        return lhs.streamID < rhs.streamID
      } else {
        return lhsStreamAge > rhsStreamAge
      }
    } else {
      return lhsRank > rhsRank
    }
  }

  private func _checkAvailableBandwidth(
    port: P,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank
  ) async throws -> Bool {
    // find all the talkers on the port
    // calculate how much bandwidth they're using
    // check if it exceeds the link speed (remember to multiply by some constant for reservation)
    // SR Class A reserves up to 75% of bandwidth. The upper limit is not configurable.
    // SR Class B reserves all the bandwidth that is not used by SR Class A. SR Class B can occupy
    // total of 75%, if no SR class A is reserved.
    true
  }

  private func _canBridgeTalker(
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
  ) async throws {
    do {
      guard let srClassID = await port
        .reverseMapSrClassPriority(priority: priorityAndRank.dataFramePriority),
        portState.srpDomainBoundaryPort[srClassID] == false
      else {
        throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      guard await !_isFanInPortLimitReached() else {
        throw MSRPFailure(systemID: port.systemID, failureCode: .fanInPortLimitReached)
      }

      guard try await _checkAvailableBandwidth(
        port: port,
        portState: portState,
        streamID: streamID,
        declarationType: declarationType,
        dataFrameParameters: dataFrameParameters,
        tSpec: tSpec,
        priorityAndRank: priorityAndRank
      )
      else {
        throw MSRPFailure(systemID: port.systemID, failureCode: .insufficientBandwidth)
      }
    } catch let error as MSRPFailure {
      throw error
    } catch {
      throw MSRPFailure(systemID: port.systemID, failureCode: .outOfMSRPResources)
    }
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

    // TL;DR: propagate Talker declarations to other ports
    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return } // don't propagate to source port

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

      let accumulatedLatency = accumulatedLatency +
        UInt32(port.getPortTcMaxLatency(for: priorityAndRank.dataFramePriority))

      if declarationType == .talkerAdvertise {
        do {
          try await _canBridgeTalker(
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
          )
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
        } catch let error as MSRPFailure {
          let talkerFailed = MSRPTalkerFailedValue(
            streamID: streamID,
            dataFrameParameters: dataFrameParameters,
            tSpec: tSpec,
            priorityAndRank: priorityAndRank,
            accumulatedLatency: accumulatedLatency,
            systemID: error.systemID,
            failureCode: error.failureCode
          )
          try await participant.join(
            attributeType: MSRPAttributeType.talkerFailed.rawValue,
            attributeValue: talkerFailed,
            isNew: true,
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
    for streamID: MSRPStreamID
  ) async throws -> (Participant<MSRPApplication>, any MSRPTalkerValue)? {
    var talkerRegistration: (Participant<MSRPApplication>, any MSRPTalkerValue)?

    await apply { participant in
      guard talkerRegistration == nil else { return }
      if let value = await participant.findAttribute(
        attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
        matching: .matchIndex(MSRPTalkerAdvertiseValue(streamID: streamID))
      ) {
        talkerRegistration = (participant, value.1 as! (any MSRPTalkerValue))
      } else if let value = await participant.findAttribute(
        attributeType: MSRPAttributeType.talkerFailed.rawValue,
        matching: .matchIndex(MSRPTalkerFailedValue(streamID: streamID))
      ) {
        talkerRegistration = (participant, value.1 as! (any MSRPTalkerValue))
      }
    }

    return talkerRegistration
  }

  private func _mergeListenerDeclarations(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    talkerRegistration: any MSRPTalkerValue
  ) async throws -> MSRPDeclarationType {
    var mergedDeclarationType: MSRPDeclarationType = if declarationType == .listenerAskingFailed ||
      talkerRegistration is MSRPTalkerFailedValue
    {
      .listenerAskingFailed
    } else {
      declarationType
    }

    await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      for listenerAttribute in await participant.findAttributes(
        attributeType: MSRPAttributeType.listener.rawValue,
        matching: .matchAnyIndex(streamID)
      ) {
        guard let declarationType = try? MSRPDeclarationType(attributeSubtype: listenerAttribute.0)
        else { continue }
        mergedDeclarationType = _mergeListener(
          declarationType: declarationType,
          with: mergedDeclarationType
        )
      }
    }

    return mergedDeclarationType
  }

  private func _updateDynamicReservationEntries(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    talkerRegistration: any MSRPTalkerValue
  ) async throws {
    if talkerRegistration is MSRPTalkerAdvertiseValue,
       declarationType == .listenerReady || declarationType == .listenerReadyFailed
    {
      // FORWARDING
    } else {
      // FILTERING
    }
  }

  private func _updateOperIdleSlope(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    talkerRegistration: any MSRPTalkerValue
  ) async throws {
    guard let controller, let bridge = controller.bridge as? any MSRPAwareBridge<P> else {
      return
    }

    let talkers = await participant.findAttributes(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchAny
    )

    var streams = [SRclassID: [MSRPTSpec]]()

    for talker in talkers.map({ $0.1 as! MSRPTalkerAdvertiseValue }) {
      guard let classID = await participant.port
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
      else { continue }
      if let index = streams.index(forKey: classID) {
        streams.values[index].append(talker.tSpec)
      } else {
        streams[classID] = [talker.tSpec]
      }
    }

    try await bridge.adjustCreditBasedShaper(
      application: self,
      port: participant.port,
      portState: portState,
      streams: streams
    )
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
    guard let talkerRegistration = try? await _findTalkerRegistration(for: streamID) else {
      throw MRPError.doNotPropagateAttribute
    }

    // TL;DR: propagate merged Listener declarations to _talker_ port
    let mergedDeclarationType = try await _mergeListenerDeclarations(
      contextIdentifier: contextIdentifier,
      port: port,
      streamID: streamID,
      declarationType: declarationType,
      talkerRegistration: talkerRegistration.1
    )
    try await talkerRegistration.0.join(
      attributeType: MSRPAttributeType.listener.rawValue,
      attributeSubtype: mergedDeclarationType.attributeSubtype!.rawValue,
      attributeValue: MSRPListenerValue(streamID: streamID),
      isNew: isNew,
      eventSource: .map
    )

    var portState: MSRPPortState<P>!
    withPortState(port: port) {
      if mergedDeclarationType != .listenerAskingFailed {
        $0.register(streamID: streamID)
      } else {
        $0.deregister(streamID: streamID)
      }
      portState = $0
    }

    if mergedDeclarationType != .listenerAskingFailed {
      // increase (if necessary) bandwidth first before updating dynamic reservation entries
      try await _updateOperIdleSlope(
        participant: talkerRegistration.0,
        portState: portState,
        streamID: streamID,
        declarationType: mergedDeclarationType,
        talkerRegistration: talkerRegistration.1
      )
    }
    try await _updateDynamicReservationEntries(
      participant: talkerRegistration.0,
      portState: portState,
      streamID: streamID,
      declarationType: mergedDeclarationType,
      talkerRegistration: talkerRegistration.1
    )
    if mergedDeclarationType == .listenerAskingFailed {
      try await _updateOperIdleSlope(
        participant: talkerRegistration.0,
        portState: portState,
        streamID: streamID,
        declarationType: mergedDeclarationType,
        talkerRegistration: talkerRegistration.1
      )
    }

    throw MRPError.doNotPropagateAttribute
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
