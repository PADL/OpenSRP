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

import AsyncExtensions
import IEEE802
import Logging
import Synchronization

public let MSRPEtherType: UInt16 = 0x22EA

protocol MSRPAwareBridge<P>: Bridge where P: AVBPort {
  func configureQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt]
  ) async throws

  func unconfigureQueues(
    port: P
  ) async throws

  func adjustCreditBasedShaper(
    port: P,
    queue: UInt,
    idleSlope: Int,
    sendSlope: Int,
    hiCredit: Int,
    loCredit: Int
  ) async throws

  func getSRClassPriorityMap(port: P) async throws -> SRClassPriorityMap?

  var srClassPriorityMapNotifications: AnyAsyncSequence<SRClassPriorityMapNotification<P>> { get }
}

extension AVBPort {
  var systemID: UInt64 {
    0x8000_0000_0000_0000 | UInt64(eui48: macAddress)
  }
}

private let DefaultSRClassPriorityMap: SRClassPriorityMap = [.A: .CA, .B: .EE]
private let DefaultDeltaBandwidths: [SRclassID: Int] = [.A: 75, .B: 0]

struct MSRPPortState<P: AVBPort>: Sendable {
  var mediaType: MSRPPortMediaType { .accessControlPort }
  var msrpPortEnabledStatus: Bool
  var streamEpochs = [MSRPStreamID: UInt32]()
  var srpDomainBoundaryPort: [SRclassID: Bool]
  var srpClassVID: [SRclassID: VLAN]
  // Table 6-5—Default SRP domain boundary port priority regeneration override values
  var neighborProtocolVersion: MSRPProtocolVersion { .v0 }
  // TODO: make these configurable
  var talkerPruning: Bool { false }
  var talkerVlanPruning: Bool { false }
  var srClassPriorityMap = SRClassPriorityMap()

  func reverseMapSrClassPriority(priority: SRclassPriority) -> SRclassID? {
    srClassPriorityMap.first(where: { $0.value == priority })?.key
  }

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
    let isAvbCapable = port.isAvbCapable || msrp._forceAvbCapable
    msrpPortEnabledStatus = isAvbCapable
    srpDomainBoundaryPort = .init(uniqueKeysWithValues: msrp._allSRClassIDs.map { (
      $0,
      !isAvbCapable
    ) })
    srpClassVID = .init(uniqueKeysWithValues: msrp._allSRClassIDs.map { (
      $0,
      msrp._srPVid
    ) })
  }
}

public final class MSRPApplication<P: AVBPort>: BaseApplication, BaseApplicationEventObserver,
  BaseApplicationContextObserver,
  ApplicationEventHandler, CustomStringConvertible, @unchecked Sendable where P == P
{
  // for now, we only operate in the Base Spanning Tree Context
  public var nonBaseContextsSupported: Bool { false }

  public var validAttributeTypes: ClosedRange<AttributeType> {
    MSRPAttributeType.validAttributeTypes
  }

  public var groupAddress: EUI48 { IndividualLANScopeGroupAddress }

  public var etherType: UInt16 { MSRPEtherType }

  public var protocolVersion: ProtocolVersion { MSRPProtocolVersion.v0.rawValue }

  public var hasAttributeListLength: Bool { true }

  let _controller: Weak<MRPController<P>>

  public var controller: MRPController<P>? { _controller.object }

  let _participants =
    Mutex<[MAPContextIdentifier: Set<Participant<MSRPApplication<P>>>]>([:])
  let _logger: Logger
  let _latencyMaxFrameSize: UInt16
  let _queues: [SRclassID: UInt]

  fileprivate let _talkerPruning: Bool
  fileprivate let _maxFanInPorts: Int
  fileprivate let _srPVid: VLAN
  fileprivate let _maxSRClass: SRclassID
  fileprivate let _portStates = Mutex<[P.ID: MSRPPortState<P>]>([:])
  fileprivate let _mmrp: MMRPApplication<P>?
  fileprivate var _priorityMapNotificationTask: Task<(), Error>?
  fileprivate let _deltaBandwidths: [SRclassID: Int]
  fileprivate let _forceAvbCapable: Bool
  fileprivate let _configureQueues: Bool

  public init(
    controller: MRPController<P>,
    talkerPruning: Bool = false,
    maxFanInPorts: Int = 0,
    latencyMaxFrameSize: UInt16 = 2000,
    srPVid: VLAN = SR_PVID,
    maxSRClass: SRclassID = .B,
    queues: [SRclassID: UInt] = [.A: 4, .B: 3],
    deltaBandwidths: [SRclassID: Int]? = nil,
    forceAvbCapable: Bool = false,
    configureQueues: Bool = false // this will become a default after further testing
  ) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    _talkerPruning = talkerPruning
    _maxFanInPorts = maxFanInPorts
    _latencyMaxFrameSize = latencyMaxFrameSize
    _srPVid = srPVid
    _maxSRClass = maxSRClass
    _queues = queues
    _deltaBandwidths = deltaBandwidths ?? DefaultDeltaBandwidths
    _forceAvbCapable = forceAvbCapable
    _configureQueues = configureQueues
    _mmrp = try? await controller.application(for: MMRPEtherType)
    try await controller.register(application: self)
    _priorityMapNotificationTask = Task {
      guard let bridge = controller.bridge as? any MSRPAwareBridge<P> else { return }

      for try await notification in bridge.srClassPriorityMapNotifications {
        guard let port = try? await controller.port(with: notification.portID) else { continue }
        withPortState(port: port) { portState in
          portState.srClassPriorityMap = notification.map
        }
      }
    }
  }

  @discardableResult
  fileprivate func withPortState<T>(
    port: P,
    body: (_: inout MSRPPortState<P>) throws -> T
  ) rethrows -> T {
    try _portStates.withLock {
      if let index = $0.index(forKey: port.id) {
        return try body(&$0.values[index])
      } else {
        throw MRPError.portNotFound
      }
    }
  }

  func onContextAdded(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext else { return }

    var srClassPriorityMap = [P.ID: SRClassPriorityMap]()

    for port in context {
      if port.isAvbCapable, let bridge = (controller?.bridge as? any MSRPAwareBridge<P>) {
        if _configureQueues {
          try await bridge.configureQueues(
            port: port,
            srClassPriorityMap: DefaultSRClassPriorityMap,
            queues: _queues
          )
          srClassPriorityMap[port.id] = DefaultSRClassPriorityMap
          _logger
            .debug(
              "MSRP: allocating port state for \(port), configuring queues with default prio map"
            )
        } else {
          srClassPriorityMap[port.id] = try? await bridge.getSRClassPriorityMap(port: port)
          _logger.debug("MSRP: allocating port state for \(port), prio map \(srClassPriorityMap)")
        }
      } else if _forceAvbCapable {
        srClassPriorityMap[port.id] = DefaultSRClassPriorityMap
        _logger.warning("MRRP: forcing port \(port) to advertise as AVB capable")
      } else {
        _logger.debug("MRRP: port \(port) is not AVB capable, skipping")
        continue
      }
    }

    try _portStates.withLock {
      for port in context {
        var portState = try MSRPPortState(msrp: self, port: port)
        if let srClassPriorityMap = srClassPriorityMap[port.id] {
          portState.srClassPriorityMap = srClassPriorityMap
        }
        $0[port.id] = portState
      }
    }

    for port in context {
      _logger.debug("MSRP: declaring domains for port \(port)")
      try await _declareDomains(port: port)
    }
  }

  func onContextUpdated(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext else { return }

    if !_forceAvbCapable {
      _portStates.withLock {
        for port in context {
          guard let index = $0.index(forKey: port.id) else { continue }
          if $0.values[index].msrpPortEnabledStatus != port.isAvbCapable {
            _logger.info("MSRP: port \(port) changed isAvbCapable, now \(port.isAvbCapable)")
          }
          $0.values[index].msrpPortEnabledStatus = port.isAvbCapable
        }
      }
    }

    Task {
      for port in context {
        _logger.debug("MSRP: re-declaring domains for port \(port)")
        try await _declareDomains(port: port)
      }
    }
  }

  func onContextRemoved(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext else { return }

    if _configureQueues {
      Task {
        for port in context {
          guard port.isAvbCapable,
                let bridge = (controller?.bridge as? any MSRPAwareBridge<P>) else { continue }
          try? await bridge.unconfigureQueues(port: port)
        }
      }
    }

    _portStates.withLock {
      for port in context {
        _logger.debug("MSRP: port \(port) disappeared, removing")
        $0.removeValue(forKey: port.id)
      }
    }
  }

  public var description: String {
    let participants: String = _participants.withLock { String(describing: $0) }
    let portStates: String = _portStates.withLock { String(describing: $0) }
    return "MSRPApplication(controller: \(controller!), participants: \(participants), portStates: \(portStates)"
  }

  public var name: String { "MSRP" }

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
      return MSRPTalkerAdvertiseValue()
    case .talkerFailed:
      return MSRPTalkerFailedValue()
    case .listener:
      return MSRPListenerValue()
    case .domain:
      return try MSRPDomainValue()
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

      let isIncluded = contextStreamID == streamID && contextDirection == direction &&
        (contextAttributeType != attributeType || contextAttributeSubtype != attributeSubtype)
      if isIncluded {
        _logger
          .debug(
            "MSRP: forcing immediate leave for stream \(streamID) owing to attribute change: \(attributeType)->\(contextAttributeType) \(String(describing: attributeSubtype))->\(String(describing: contextAttributeSubtype))"
          )
      }
      return isIncluded
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
    let talkerRegistration = try await _findTalkerRegistration(for: streamID)
    let declarationType: MSRPDeclarationType
    guard let talkerRegistration else {
      throw MRPError.participantNotFound
    }
    if talkerRegistration.1 is MSRPTalkerAdvertiseValue {
      declarationType = .talkerAdvertise
    } else {
      declarationType = .talkerFailed
    }
    try await leave(
      attributeType: declarationType.attributeType.rawValue,
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
    declarationType: MSRPDeclarationType,
    on port: P? = nil
  ) async throws {
    try await apply { participant in
      if let port, port != participant.port { return }
      try await join(
        attributeType: declarationType.attributeType.rawValue,
        attributeValue: MSRPListenerValue(streamID: streamID),
        isNew: true,
        for: MAPBaseSpanningTreeContext
      )
    }
  }

  // On receipt of a DEREGISTER_ATTACH.request the MSRP Participant shall issue
  // a MAD_Leave.request service primitive (10.2, 10.3) with the attribute_type
  // set to the appropriate Listener Attribute Type (35.2.2.4). The
  // attribute_value parameter shall carry the StreamID and the Declaration
  // Type currently associated with the StreamID.
  public func deregisterAttach(
    streamID: MSRPStreamID,
    on port: P? = nil
  ) async throws {
    try await apply { participant in
      if let port, port != participant.port { return }
      guard let listenerAttribute = await participant.findAttribute(
        attributeType: MSRPAttributeType.listener.rawValue,
        matching: .matchAny
      ),
        let declarationType = try MSRPDeclarationType(attributeSubtype: listenerAttribute.0)
      else {
        return
      }

      try await leave(
        attributeType: declarationType.attributeType.rawValue,
        attributeValue: MSRPListenerValue(streamID: streamID),
        for: MAPBaseSpanningTreeContext
      )
    }
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
    eventSource: EventSource
  ) async -> Bool {
    if _talkerPruning || portState.talkerPruning {
      if let mmrpParticipant = try? _mmrp?.findParticipant(port: port),
         await mmrpParticipant.findAttribute(
           attributeType: MMRPAttributeType.mac.rawValue,
           matching: .matchEqual(MMRPMACValue(macAddress: dataFrameParameters.destinationAddress))
         ) == nil
      {
        _logger.trace("MSRP: pruning talker stream \(streamID) on port \(port)")
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
        return lhs.streamID.id < rhs.streamID.id
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
    srClassID lowestSRClassID: SRclassID,
    bandwidthUsed: [SRclassID: Int]
  ) -> Bool {
    var bandwidthLimit = 0
    var aggregateBandwidth = 0

    for item in (lowestSRClassID.rawValue...SRclassID.A.rawValue)
      .map({ SRclassID(rawValue: $0)! })
    {
      bandwidthLimit += _deltaBandwidths[item] ?? 0
      aggregateBandwidth += bandwidthUsed[item] ?? 0
    }

    if bandwidthLimit > 100 {
      bandwidthLimit = 100
    }

    return Double(aggregateBandwidth) < Double(port.linkSpeed) * Double(bandwidthLimit) /
      Double(100)
  }

  private func _checkAvailableBandwidth(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank
  ) async throws -> Bool {
    var bandwidthUsed = [SRclassID: Int]()

    let port = participant.port
    let provisionalTalker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParameters,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 0 // or this
    )

    let talkers = await participant.findAttributes(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchAny
    ).filter {
      ($0.1 as! MSRPTalkerAdvertiseValue).streamID != streamID
    }
    for talker in [provisionalTalker] + talkers.map({ $0.1 as! MSRPTalkerAdvertiseValue }) {
      guard let srClassID = portState
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
      else {
        continue
      }
      let classMeasurementInterval = try srClassID
        .classMeasurementInterval // number of intervals in usec
      let maxFrameRate = Int(talker.tSpec.maxIntervalFrames) *
        (1_000_000 / classMeasurementInterval) // number of frames per second
      let bw = maxFrameRate * Int(tSpec.maxFrameSize) * 8 / 1000 // bandwidth used in kbps
      if let index = bandwidthUsed.index(forKey: srClassID) {
        bandwidthUsed.values[index] += bw
      } else {
        bandwidthUsed[srClassID] = bw
      }
    }

    for srClassID in SRclassID.allCases {
      guard _checkAvailableBandwidth(
        port: port,
        portState: portState,
        srClassID: srClassID,
        bandwidthUsed: bandwidthUsed
      ) else {
        _logger
          .debug(
            "MSRP: bandwidth limit reached for class \(srClassID), port \(port), link speed \(port.linkSpeed), deltas \(_deltaBandwidths), used \(bandwidthUsed)"
          )
        return false
      }
    }

    return true
  }

  private func _canBridgeTalker(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank,
    accumulatedLatency: UInt32,
    isNew: Bool,
    eventSource: EventSource
  ) async throws {
    let port = participant.port

    do {
      guard portState.msrpPortEnabledStatus else {
        _logger.error("MSRP: port \(port) is not enabled")
        throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      if let existingTalkerRegistration = await _findTalkerRegistration(
        for: streamID,
        participant: participant
      )?.1,
        existingTalkerRegistration.dataFrameParameters != dataFrameParameters
      {
        _logger
          .error(
            "MSRP: stream \(streamID) is already registered on port \(port) with \(dataFrameParameters)"
          )
        throw MSRPFailure(systemID: port.systemID, failureCode: .streamIDAlreadyInUse)
      }

      // TODO: should we check explicitly for false
      guard let srClassID = portState
        .reverseMapSrClassPriority(priority: priorityAndRank.dataFramePriority),
        portState.srpDomainBoundaryPort[srClassID] != true
      else {
        _logger.error("MSRP: port \(port) is a SRP domain boundary port for \(priorityAndRank)")
        throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      guard await !_isFanInPortLimitReached() else {
        _logger.error("MSRP: fan in port limit reached")
        throw MSRPFailure(systemID: port.systemID, failureCode: .fanInPortLimitReached)
      }

      guard try await _checkAvailableBandwidth(
        participant: participant,
        portState: portState,
        streamID: streamID,
        dataFrameParameters: dataFrameParameters,
        tSpec: tSpec,
        priorityAndRank: priorityAndRank
      )
      else {
        _logger.error("MSRP: bandwidth limit exceeded for stream \(streamID) on port \(port)")
        throw MSRPFailure(systemID: port.systemID, failureCode: .insufficientBandwidth)
      }
    } catch let error as MSRPFailure {
      throw error
    } catch {
      _logger.error("MSRP: cannot bridge talker: generic error \(error)")
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
    eventSource: EventSource
  ) async throws {
    _logger
      .info(
        "MSRP: register stream indication from port \(port) streamID \(streamID) declarationType \(declarationType) dataFrameParameters \(dataFrameParameters) isNew \(isNew) source \(eventSource)"
      )

    // TL;DR: propagate Talker declarations to other ports
    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return } // don't propagate to source port

      let port = participant.port
      var portState: MSRPPortState<P>?
      withPortState(port: port) { portState = $0 }
      guard let portState else { return }

      guard await !_shouldPruneTalkerDeclaration(
        port: port,
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
        _logger
          .debug(
            "MSRP: pruned talker declaration for stream \(streamID) destination \(dataFrameParameters) on port \(port)"
          )
        return
      }

      var accumulatedLatency = accumulatedLatency
      do {
        let portTcMaxLatency = try await port
          .getPortTcMaxLatency(for: priorityAndRank.dataFramePriority)
        guard portTcMaxLatency >= 0 else { throw MRPError.portLatencyIsNegative(portTcMaxLatency) }
        accumulatedLatency += UInt32(portTcMaxLatency)
      } catch {
        _logger
          .error(
            "MSRP: failed to request max latency for \(port) priority \(priorityAndRank.dataFramePriority): \(error)"
          )
        accumulatedLatency += 500 // clause 35.2.2.8.6, 500ns default
      }

      if declarationType == .talkerAdvertise {
        do {
          try await _canBridgeTalker(
            participant: participant,
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
          _logger
            .debug(
              "MSRP: propagating talker advertise \(talkerAdvertise) to port \(port)"
            )
          try await participant.join(
            attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
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
          _logger
            .debug(
              "MSRP: propagating talker failed \(talkerFailed) on port \(port), error \(error)"
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
        _logger
          .debug(
            "MSRP: propagating talker failed \(talkerFailed) to port \(port), transitive"
          )
        try await participant.join(
          attributeType: MSRPAttributeType.talkerFailed.rawValue,
          attributeValue: talkerFailed,
          isNew: false,
          eventSource: .map
        )
      }
    }
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
  ) async -> (Participant<MSRPApplication>, any MSRPTalkerValue)? {
    if let value = await participant.findAttribute(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchIndex(MSRPTalkerAdvertiseValue(streamID: streamID))
    ) {
      (participant, value.1 as! (any MSRPTalkerValue))
    } else if let value = await participant.findAttribute(
      attributeType: MSRPAttributeType.talkerFailed.rawValue,
      matching: .matchIndex(MSRPTalkerFailedValue(streamID: streamID))
    ) {
      (participant, value.1 as! (any MSRPTalkerValue))
    } else {
      nil
    }
  }

  private func _findTalkerRegistration(
    for streamID: MSRPStreamID
  ) async throws -> (Participant<MSRPApplication>, any MSRPTalkerValue)? {
    var talkerRegistration: (Participant<MSRPApplication>, any MSRPTalkerValue)?

    await apply { participant in
      talkerRegistration = await _findTalkerRegistration(for: streamID, participant: participant)
    }

    return talkerRegistration
  }

  private func _mergeListenerDeclarations(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    talkerRegistration: any MSRPTalkerValue,
    isJoin: Bool
  ) async throws -> MSRPDeclarationType? {
    var mergedDeclarationType: MSRPDeclarationType? = if isJoin {
      if declarationType == .listenerAskingFailed ||
        talkerRegistration is MSRPTalkerFailedValue
      {
        .listenerAskingFailed
      } else {
        declarationType
      }
    } else {
      nil
    }

    // collect listener declarations from all ports except the declaration being processed
    // by the caller, and merge declaration type
    await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return }
      for listenerAttribute in await participant.findAttributes(
        attributeType: MSRPAttributeType.listener.rawValue,
        matching: .matchAnyIndex(streamID.id)
      ) {
        guard let declarationType = try? MSRPDeclarationType(attributeSubtype: listenerAttribute.0)
        else { continue }
        if mergedDeclarationType == nil {
          mergedDeclarationType = declarationType
        } else {
          mergedDeclarationType = _mergeListener(
            declarationType: declarationType,
            with: mergedDeclarationType
          )
        }
      }
    }

    return mergedDeclarationType
  }

  private func _updateDynamicReservationEntries(
    port: P,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType?,
    talkerRegistration: any MSRPTalkerValue
  ) async throws {
    guard let controller,
          let bridge = controller.bridge as? any MMRPAwareBridge<P>
    else { throw MRPError.internalError }
    if talkerRegistration is MSRPTalkerAdvertiseValue,
       declarationType == .listenerReady || declarationType == .listenerReadyFailed
    {
      _logger.debug("MSRP: registering FDB entries for \(talkerRegistration.dataFrameParameters)")
      try await bridge.register(
        macAddress: talkerRegistration.dataFrameParameters.destinationAddress,
        vlan: talkerRegistration.dataFrameParameters.vlanIdentifier,
        on: [port]
      )
    } else {
      _logger.debug("MSRP: deregistering FDB entries for \(talkerRegistration.dataFrameParameters)")
      try? await bridge.deregister(
        macAddress: talkerRegistration.dataFrameParameters.destinationAddress,
        vlan: talkerRegistration.dataFrameParameters.vlanIdentifier,
        from: [port]
      )
    }
  }

  private func _updateOperIdleSlope(
    port: P,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    talkerRegistration: any MSRPTalkerValue
  ) async throws {
    guard let controller, let bridge = controller.bridge as? any MSRPAwareBridge<P> else {
      return
    }

    guard let participant = try? findParticipant(port: port) else {
      _logger.info("MSRP: failed to find participant for port \(port)")
      return
    }

    let talkers = await participant.findAttributes(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchAny
    )

    // assert that talker has already been added to participant
    precondition(
      talkers
        .contains(where: {
          ($0.1 as! MSRPTalkerAdvertiseValue).streamID == talkerRegistration.streamID
        })
    )

    var streams = [SRclassID: [MSRPTSpec]]()

    for talker in talkers.map({ $0.1 as! MSRPTalkerAdvertiseValue }) {
      guard let classID = portState
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
      else { continue }
      if let index = streams.index(forKey: classID) {
        streams.values[index].append(talker.tSpec)
      } else {
        streams[classID] = [talker.tSpec]
      }
    }

    _logger.debug("MSRP: adjusting idle slope, port \(port), streams \(streams)")

    try await bridge.adjustCreditBasedShaper(
      application: self,
      port: port,
      portState: portState,
      streams: streams
    )
  }

  private func _updatePortParameters(
    port: P,
    streamID: MSRPStreamID,
    mergedDeclarationType: MSRPDeclarationType?,
    talkerRegistration: (Participant<MSRPApplication>, any MSRPTalkerValue)
  ) async throws {
    var portState: MSRPPortState<P>?
    withPortState(port: port) {
      if mergedDeclarationType == .listenerReady || mergedDeclarationType == .listenerReadyFailed {
        $0.register(streamID: streamID)
      } else {
        $0.deregister(streamID: streamID)
      }
      portState = $0
    }
    guard let portState else { throw MRPError.portNotFound }

    _logger
      .debug(
        "MSRP: updating port parameters for port \(port) streamID \(streamID) declaration type \(String(describing: mergedDeclarationType)) talker \(talkerRegistration.0.port):\(talkerRegistration.1)"
      )

    do {
      if mergedDeclarationType == .listenerReady || mergedDeclarationType == .listenerReadyFailed {
        // increase (if necessary) bandwidth first before updating dynamic reservation entries
        try await _updateOperIdleSlope(
          port: port,
          portState: portState,
          streamID: streamID,
          talkerRegistration: talkerRegistration.1
        )
      }
      try await _updateDynamicReservationEntries(
        port: port,
        portState: portState,
        streamID: streamID,
        declarationType: mergedDeclarationType,
        talkerRegistration: talkerRegistration.1
      )
      if mergedDeclarationType == nil || mergedDeclarationType == .listenerAskingFailed {
        try await _updateOperIdleSlope(
          port: port,
          portState: portState,
          streamID: streamID,
          talkerRegistration: talkerRegistration.1
        )
      }
    } catch {
      _logger
        .error(
          "MSRP: failed to update port parameters for stream \(streamID): \(error)\(_forceAvbCapable ? ", ignoring" : "")"
        )
      guard _forceAvbCapable else { throw error }
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
    eventSource: EventSource
  ) async throws {
    guard let talkerRegistration = try? await _findTalkerRegistration(for: streamID) else {
      _logger
        .error(
          "MSRP: could not find talker registration for listener stream \(streamID) on port \(port)"
        )
      return
    }

    // TL;DR: propagate merged Listener declarations to _talker_ port
    let mergedDeclarationType = try await _mergeListenerDeclarations(
      contextIdentifier: contextIdentifier,
      port: port,
      streamID: streamID,
      declarationType: declarationType,
      talkerRegistration: talkerRegistration.1,
      isJoin: true
    )

    _logger
      .info(
        "MSRP: register attach indication from port \(port) streamID \(streamID) declarationType \(declarationType) to participant \(talkerRegistration)"
      )

    try await talkerRegistration.0.join(
      attributeType: MSRPAttributeType.listener.rawValue,
      attributeSubtype: mergedDeclarationType!.attributeSubtype!.rawValue,
      attributeValue: MSRPListenerValue(streamID: streamID),
      isNew: isNew,
      eventSource: .map
    )
    try await _updatePortParameters(
      port: port,
      streamID: streamID,
      mergedDeclarationType: mergedDeclarationType,
      talkerRegistration: talkerRegistration
    )
  }

  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) async throws {
    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }

    // 35.2.4 (d) A MAD_Join.indication adds a new attribute to MAD (with isNew TRUE)
    guard shouldPropagate(eventSource: eventSource) else {
      _logger
        .trace(
          "MSRP: ignoring join indication for attribute \(attributeType) isNew \(isNew) subtype \(String(describing: attributeSubtype)) value \(attributeValue) source \(eventSource) port \(port)"
        )
      // don't recursively invoke MAP
      throw MRPError.doNotPropagateAttribute
    }

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
      else { throw MRPError.invalidMSRPDeclarationType }
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
      let isEndStation = await controller?.isEndStation ?? false
      withPortState(port: port) { portState in
        let srClassPriority = portState.srClassPriorityMap[domain.srClassID]
        let isSrpDomainBoundaryPort = srClassPriority != domain.srClassPriority
        _logger
          .debug(
            "MSRP: port \(port) srClassID \(domain.srClassID) local srClassPriority \(String(describing: srClassPriority)) peer srClassPriority \(domain.srClassPriority): \(isSrpDomainBoundaryPort ? "is" : "not") a domain boundary port"
          )
        portState.srpDomainBoundaryPort[domain.srClassID] = isSrpDomainBoundaryPort
        if !isSrpDomainBoundaryPort, isEndStation {
          portState.srpClassVID[domain.srClassID] = VLAN(vid: domain.srClassVID)
        }
      }
    }
    throw MRPError.doNotPropagateAttribute
  }

  // On receipt of a MAD_Leave.indication service primitive (10.2, 10.3) with
  // an attribute_type of Talker Advertise, Talker Failed, or Talker Enhanced
  // (35.2.2.4), the MSRP application shall issue a
  // DEREGISTER_STREAM.indication to the Listener application entity.
  private func _onDeregisterStreamIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    eventSource: EventSource
  ) async throws {
    _logger
      .info(
        "MSRP: deregister stream indication from port \(port) streamID \(streamID) source \(eventSource)"
      )

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
  }

  // On receipt of a MAD_Leave.indication service primitive (10.2, 10.3) with
  // an attribute_type of Listener (35.2.2.4), the MSRP application shall issue
  // a DEREGISTER_ATTACH.indication to the Talker application entity.
  private func _onDeregisterAttachIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    eventSource: EventSource
  ) async throws {
    _logger
      .info(
        "MSRP: deregister attach indication from port \(port) streamID \(streamID) source \(eventSource)"
      )

    // On receipt of a MAD_Leave.indication for a Listener Declaration, if the
    // StreamID of the Declaration matches a Stream that the Talker is
    // transmitting, then the Talker shall stop the transmission for this
    // Stream, if it is transmitting.
    guard let talkerRegistration = try? await _findTalkerRegistration(for: streamID) else {
      return
    }

    // TL;DR: propagate merged Listener declarations to _talker_ port
    let mergedDeclarationType = try await _mergeListenerDeclarations(
      contextIdentifier: contextIdentifier,
      port: port,
      streamID: streamID,
      declarationType: declarationType,
      talkerRegistration: talkerRegistration.1,
      isJoin: false
    )

    if let mergedDeclarationType {
      try await talkerRegistration.0.join(
        attributeType: MSRPAttributeType.listener.rawValue,
        attributeSubtype: mergedDeclarationType.attributeSubtype!.rawValue,
        attributeValue: MSRPListenerValue(streamID: streamID),
        isNew: true,
        eventSource: .map
      )
    } else {
      try await talkerRegistration.0.leave(
        attributeType: MSRPAttributeType.listener.rawValue,
        attributeValue: MSRPListenerValue(streamID: streamID),
        eventSource: .map
      )
    }

    try await _updatePortParameters(
      port: port,
      streamID: streamID,
      mergedDeclarationType: mergedDeclarationType,
      talkerRegistration: talkerRegistration
    )
  }

  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: EventSource
  ) async throws {
    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }

    guard shouldPropagate(eventSource: eventSource) else {
      _logger
        .trace(
          "MSRP: ignoring leave indication for attribute \(attributeType) subtype \(String(describing: attributeSubtype)) value \(attributeValue) source \(eventSource) port \(port)"
        )
      // don't recursively invoke MAP
      throw MRPError.doNotPropagateAttribute
    }

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
      else { throw MRPError.invalidMSRPDeclarationType }
      try await _onDeregisterAttachIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: (attributeValue as! MSRPListenerValue).streamID,
        declarationType: declarationType,
        eventSource: eventSource
      )
    case .domain:
      let domain = (attributeValue as! MSRPDomainValue)
      withPortState(port: port) { portState in
        portState.srpDomainBoundaryPort[domain.srClassID] = nil
      }
    }
    throw MRPError.doNotPropagateAttribute
  }

  private func _declareDomain(
    srClassID: SRclassID,
    on participant: Participant<MSRPApplication>
  ) async throws {
    var domain: MSRPDomainValue?

    withPortState(port: participant.port) { portState in
      if let srClassPriority = portState.srClassPriorityMap[srClassID] {
        domain = MSRPDomainValue(
          srClassID: srClassID,
          srClassPriority: srClassPriority,
          srClassVID: (portState.srpClassVID[srClassID] ?? _srPVid).vid
        )
      }
    }

    if let domain {
      _logger.info("MSRP: declaring domain \(domain)")
      try await participant.join(
        attributeType: MSRPAttributeType.domain.rawValue,
        attributeValue: domain,
        isNew: true,
        eventSource: .application
      )
    } else {
      _logger
        .warning(
          "MSRP: not declaring domain for SR class \(srClassID) as no priority mapping found"
        )
    }
  }

  fileprivate var _allSRClassIDs: [SRclassID] {
    Array((_maxSRClass.rawValue...SRclassID.A.rawValue).map { SRclassID(rawValue: $0)! })
  }

  private func _declareDomains(port: P) async throws {
    let participant = try findParticipant(port: port)
    for srClassID in _allSRClassIDs {
      try await _declareDomain(srClassID: srClassID, on: participant)
    }
  }
}
