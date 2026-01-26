//
// Copyright (c) 2024-2025 PADL Software Pty Ltd
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
import BinaryParsing
import IEEE802
import Logging
import Synchronization
#if canImport(FlyingFox)
import FlyingFox
#endif

public let MSRPEtherType: UInt16 = 0x22EA

public struct MSRPApplicationFlags: OptionSet, Sendable {
  public typealias RawValue = UInt8

  public let rawValue: RawValue

  public init(rawValue: RawValue) { self.rawValue = rawValue }

  public static let forceAvbCapable = Self(rawValue: 1 << 0)
  public static let configureQueues = Self(rawValue: 1 << 1)
  public static let ignoreAsCapable = Self(rawValue: 1 << 2)
  public static let talkerPruning = Self(rawValue: 1 << 3)

  public static let defaultFlags = Self([.ignoreAsCapable])
}

protocol MSRPAwareBridge<P>: Bridge where P: AVBPort {
  func configureQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
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

public extension AVBPort {
  var systemID: MSRPSystemID {
    MSRPSystemID(id: 0x8000_0000_0000_0000 | UInt64(eui48: macAddress))
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
          let time = try? P.timeSinceEpoch(),
          time >= epoch
    else {
      return 0
    }

    return time - epoch
  }

  func getDomain(for srClassID: SRclassID, defaultSRPVid: VLAN) -> MSRPDomainValue? {
    if let srClassPriority = srClassPriorityMap[srClassID] {
      MSRPDomainValue(
        srClassID: srClassID,
        srClassPriority: srClassPriority,
        srClassVID: (srpClassVID[srClassID] ?? defaultSRPVid).vid
      )
    } else {
      nil
    }
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
  BaseApplicationContextObserver, CustomStringConvertible, @unchecked Sendable where P == P
{
  private typealias TalkerRegistration = (Participant<MSRPApplication>, any MSRPTalkerValue)

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

  let _srPVid: VLAN
  let _deltaBandwidths: [SRclassID: Int]
  let _maxTalkerAttributes: Int
  let _flags: MSRPApplicationFlags

  fileprivate let _maxFanInPorts: Int
  fileprivate let _maxSRClass: SRclassID
  fileprivate let _portStates = Mutex<[P.ID: MSRPPortState<P>]>([:])
  fileprivate let _mmrp: MMRPApplication<P>?
  fileprivate var _priorityMapNotificationTask: Task<(), Error>?

  // Convenience accessors for flags
  fileprivate var _forceAvbCapable: Bool { _flags.contains(.forceAvbCapable) }
  fileprivate var _configureQueues: Bool { _flags.contains(.configureQueues) }
  var _ignoreAsCapable: Bool { _flags.contains(.ignoreAsCapable) }
  fileprivate var _talkerPruning: Bool { _flags.contains(.talkerPruning) }

  public init(
    controller: MRPController<P>,
    flags: MSRPApplicationFlags = .defaultFlags,
    maxFanInPorts: Int = 0,
    latencyMaxFrameSize: UInt16 = 2000,
    srPVid: VLAN = SR_PVID,
    maxSRClass: SRclassID = .B,
    queues: [SRclassID: UInt] = [.A: 4, .B: 3],
    deltaBandwidths: [SRclassID: Int]? = nil,
    maxTalkerAttributes: Int = 150
  ) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    _flags = flags
    _maxFanInPorts = maxFanInPorts
    _latencyMaxFrameSize = latencyMaxFrameSize
    _srPVid = srPVid
    _maxSRClass = maxSRClass
    _queues = queues
    _deltaBandwidths = deltaBandwidths ?? DefaultDeltaBandwidths
    _maxTalkerAttributes = maxTalkerAttributes
    _mmrp = try? await controller.application(for: MMRPEtherType)
    try await controller.register(application: self)
    _priorityMapNotificationTask = Task {
      guard let bridge = controller.bridge as? any MSRPAwareBridge<P> else { return }

      for try await notification in bridge.srClassPriorityMapNotifications {
        guard let port = try? await controller.port(with: notification.portID) else { continue }
        try? withPortState(port: port) { portState in
          portState.srClassPriorityMap = notification.map
        }
      }
    }
  }

  deinit {
    _priorityMapNotificationTask?.cancel()
  }

  @discardableResult
  func withPortState<T>(
    port: P,
    _ body: (_: inout MSRPPortState<P>) throws -> T
  ) throws -> T {
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

    guard let bridge = (controller?.bridge as? any MSRPAwareBridge<P>) else {
      _logger.error("MSRP: bridge is not MSRP-aware, cannot declare domains")
      return
    }

    for port in context {
      if _configureQueues {
        try? await bridge.unconfigureQueues(port: port)
        try await bridge.configureQueues(
          port: port,
          srClassPriorityMap: DefaultSRClassPriorityMap,
          queues: _queues,
          forceAvbCapable: _forceAvbCapable
        )
        srClassPriorityMap[port.id] = DefaultSRClassPriorityMap
        _logger
          .debug(
            "MSRP: allocating port state for \(port), configuring queues with default prio map"
          )
      } else if port.isAvbCapable {
        srClassPriorityMap[port.id] = try? await bridge.getSRClassPriorityMap(port: port)
        _logger.debug("MSRP: allocating port state for \(port), prio map \(srClassPriorityMap)")
      } else if _forceAvbCapable {
        srClassPriorityMap[port.id] = DefaultSRClassPriorityMap
        _logger.warning("MSRP: forcing port \(port) to advertise as AVB capable")
      } else {
        _logger.debug("MSRP: port \(port) is not AVB capable, skipping")
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
          do {
            try await bridge.unconfigureQueues(port: port)
          } catch {
            _logger.error("MSRP: failed to unconfigure queues for port \(port): \(error)")
          }
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
    return "MSRPApplication(controller: \(controller?.description ?? "<nil>"), participants: \(participants), portStates: \(portStates)"
  }

  public var name: String { "MSRP" }

  public func deserialize(
    attributeOfType attributeType: AttributeType,
    from input: inout ParserSpan
  ) throws -> any Value {
    guard let attributeType = MSRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .talkerAdvertise:
      return try MSRPTalkerAdvertiseValue(parsing: &input)
    case .talkerFailed:
      return try MSRPTalkerFailedValue(parsing: &input)
    case .listener:
      return try MSRPListenerValue(parsing: &input)
    case .domain:
      return try MSRPDomainValue(parsing: &input)
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
    guard let talkerRegistration = await _findTalkerRegistration(for: streamID) else {
      throw MRPError.participantNotFound
    }
    let declarationType: MSRPDeclarationType = if talkerRegistration.1 is MSRPTalkerAdvertiseValue {
      .talkerAdvertise
    } else {
      .talkerFailed
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
        attributeType: MSRPAttributeType.listener.rawValue,
        attributeSubtype: declarationType.attributeSubtype?.rawValue,
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

      guard let listenerRegistration = await _findListenerRegistration(
        for: streamID,
        participant: participant
      ) else { return }

      try await leave(
        attributeType: MSRPAttributeType.listener.rawValue,
        attributeSubtype: listenerRegistration.1.rawValue,
        attributeValue: listenerRegistration.0,
        for: MAPBaseSpanningTreeContext
      )
    }
  }

  public func periodic(for contextIdentifier: MAPContextIdentifier? = nil) async throws {
    // 5.4.4 the Periodic Transmission state machine (10.7.10) is specifically
    // excluded from MSRP
  }
}

extension MSRPApplication {
  // Enforce mutual exclusion between talkerAdvertise and talkerFailed on a participant
  private func _enforceTalkerMutualExclusion(
    participant: Participant<MSRPApplication>,
    declarationType: MSRPDeclarationType,
    streamID: MSRPStreamID,
    eventSource: EventSource
  ) async throws {
    let oppositeType: MSRPAttributeType = declarationType == .talkerAdvertise ? .talkerFailed :
      .talkerAdvertise

    let oppositeAttributes = await participant.findAttributes(
      attributeType: oppositeType.rawValue,
      matching: .matchAnyIndex(streamID.index)
    )

    for (_, attributeValue) in oppositeAttributes {
      if eventSource == .map {
        try? await participant.leave(
          attributeType: oppositeType.rawValue,
          attributeValue: attributeValue,
          eventSource: eventSource
        )
      } else {
        try? await participant.deregister(
          attributeType: oppositeType.rawValue,
          attributeValue: attributeValue,
          eventSource: eventSource
        )
      }
    }
  }

  private func _shouldPruneTalkerDeclaration(
    port: P,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank,
    accumulatedLatency: UInt32,
    isNew: Bool,
    eventSource: EventSource
  ) async -> Bool {
    guard let portState = try? withPortState(port: port, { $0 }) else { return true }

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

    return fanInCount >= _maxFanInPorts
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

  private func _checkAsCapable(
    port: P,
    attributeType: MSRPAttributeType,
    isJoin: Bool
  ) async throws {
    guard !_ignoreAsCapable else { return }

    guard await (try? port.isAsCapable) ?? false else {
      _logger
        .trace(
          "MSRP: ignoring \(isJoin ? "join" : "leave") indication for attribute \(attributeType) as port is not asCapable"
        )
      throw MRPError.doNotPropagateAttribute
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

  func _calculateBandwidthUsed(
    portState: MSRPPortState<P>,
    talker: MSRPTalkerAdvertiseValue
  ) throws -> Int {
    guard let srClassID = portState
      .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
    else {
      return 0
    }

    let (_, bandwidthUsed) = try calculateBandwidthUsed(
      srClassID: srClassID,
      tSpec: talker.tSpec,
      maxFrameSize: _latencyMaxFrameSize
    )

    return bandwidthUsed
  }

  func _calculateBandwidthUsed(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    provisionalTalker: MSRPTalkerAdvertiseValue? = nil
  ) async throws -> [SRclassID: Int] {
    var bandwidthUsed = [SRclassID: Int]()

    // Find all active talkers (those with listeners in ready or readyFailed state)
    var talkers = await _findActiveTalkers(participant: participant)

    // Add provisional talker if provided (for bandwidth admission control check)
    if let provisionalTalker { talkers.insert(provisionalTalker) }

    for talker in talkers {
      guard let srClassID = portState
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
      else {
        continue
      }
      let bw = try _calculateBandwidthUsed(portState: portState, talker: talker)
      if let index = bandwidthUsed.index(forKey: srClassID) {
        bandwidthUsed.values[index] += bw
      } else {
        bandwidthUsed[srClassID] = bw
      }
    }

    return bandwidthUsed
  }

  private func _checkAvailableBandwidth(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    dataFrameParameters: MSRPDataFrameParameters,
    tSpec: MSRPTSpec,
    priorityAndRank: MSRPPriorityAndRank
  ) async throws -> Bool {
    let port = participant.port
    let provisionalTalker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParameters,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 0 // or this
    )

    let bandwidthUsed = try await _calculateBandwidthUsed(
      participant: participant,
      portState: portState,
      provisionalTalker: provisionalTalker
    )

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
    port: P,
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
      guard let portState = try? withPortState(port: port, { $0 }) else {
        throw MSRPFailure(systemID: port.systemID, failureCode: .insufficientBridgeResources)
      }

      guard portState.msrpPortEnabledStatus else {
        _logger.error("MSRP: port \(port) is not enabled")
        throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      if let existingTalkerRegistration = await _findTalkerRegistration(
        for: streamID,
        participant: participant
      ), existingTalkerRegistration.dataFrameParameters != dataFrameParameters {
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

      guard tSpec.maxIntervalFrames != 0 else {
        _logger.error("MSRP: MaxIntervalFrames cannot be zero")
        throw MSRPFailure(systemID: port.systemID, failureCode: .insufficientBridgeResources)
      }

      // maxFrameSize does not include preamble, IEEE 802.3 header,
      // Priority/VID tag, CRC, interframe gap
      guard calcFrameSize(tSpec) <= port.mtu else {
        _logger.error("MSRP: MaxFrameSize \(tSpec.maxFrameSize) is too large for media")
        throw MSRPFailure(systemID: port.systemID, failureCode: .maxFrameSizeTooLargeForMedia)
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
    talkerValue: any MSRPTalkerValue,
    failureInformation: MSRPFailure?,
    isNew: Bool,
    eventSource: EventSource
  ) async throws {
    let declarationType = talkerValue.declarationType!

    guard await !_isMaxTalkerAttributesRegistered else {
      _logger
        .info(
          "MSRP: ignoring register stream indication from port \(port) streamID \(talkerValue.streamID) declarationType \(declarationType) as max talker attributes registered"
        )
      return
    }

    _logger
      .info(
        "MSRP: register stream indication from port \(port) streamID \(talkerValue.streamID) declarationType \(declarationType) dataFrameParameters \(talkerValue.dataFrameParameters) isNew \(isNew) source \(eventSource)"
      )

    // Deregister the opposite talker type from the peer to ensure mutual exclusion
    if eventSource == .peer {
      let sourceParticipant = try findParticipant(for: contextIdentifier, port: port)
      try await _enforceTalkerMutualExclusion(
        participant: sourceParticipant,
        declarationType: declarationType,
        streamID: talkerValue.streamID,
        eventSource: .peer
      )
    }

    // TL;DR: propagate Talker declarations to other ports
    try await apply(for: contextIdentifier) { participant in
      guard participant.port != port else { return } // don't propagate to source port

      let port = participant.port

      guard await !_shouldPruneTalkerDeclaration(
        port: port,
        streamID: talkerValue.streamID,
        declarationType: declarationType,
        dataFrameParameters: talkerValue.dataFrameParameters,
        tSpec: talkerValue.tSpec,
        priorityAndRank: talkerValue.priorityAndRank,
        accumulatedLatency: talkerValue.accumulatedLatency,
        isNew: isNew,
        eventSource: eventSource
      ) else {
        _logger
          .debug(
            "MSRP: pruned talker declaration for stream \(talkerValue.streamID) destination \(talkerValue.dataFrameParameters) on port \(port)"
          )
        return
      }

      var accumulatedLatency = talkerValue.accumulatedLatency
      do {
        let portTcMaxLatency = try await port
          .getPortTcMaxLatency(for: talkerValue.priorityAndRank.dataFramePriority)
        guard portTcMaxLatency >= 0 else { throw MRPError.portLatencyIsNegative(portTcMaxLatency) }
        accumulatedLatency += UInt32(portTcMaxLatency)
      } catch {
        _logger
          .error(
            "MSRP: failed to request max latency for \(port) priority \(talkerValue.priorityAndRank.dataFramePriority): \(error)"
          )
        accumulatedLatency += 500 // clause 35.2.2.8.6, 500ns default
      }

      // Leave the opposite talker declaration type to ensure mutual exclusion
      // (per spec, only one talker declaration type should exist per stream)
      try await _enforceTalkerMutualExclusion(
        participant: participant,
        declarationType: declarationType,
        streamID: talkerValue.streamID,
        eventSource: .map
      )

      if declarationType == .talkerAdvertise {
        do {
          try await _canBridgeTalker(
            participant: participant,
            port: port,
            streamID: talkerValue.streamID,
            declarationType: declarationType,
            dataFrameParameters: talkerValue.dataFrameParameters,
            tSpec: talkerValue.tSpec,
            priorityAndRank: talkerValue.priorityAndRank,
            accumulatedLatency: accumulatedLatency,
            isNew: isNew,
            eventSource: eventSource
          )
          let talkerAdvertise = MSRPTalkerAdvertiseValue(
            streamID: talkerValue.streamID,
            dataFrameParameters: talkerValue.dataFrameParameters,
            tSpec: talkerValue.tSpec,
            priorityAndRank: talkerValue.priorityAndRank,
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
            streamID: talkerValue.streamID,
            dataFrameParameters: talkerValue.dataFrameParameters,
            tSpec: talkerValue.tSpec,
            priorityAndRank: talkerValue.priorityAndRank,
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
          streamID: talkerValue.streamID,
          dataFrameParameters: talkerValue.dataFrameParameters,
          tSpec: talkerValue.tSpec,
          priorityAndRank: talkerValue.priorityAndRank,
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

    // Accommodate the race condition where a listener is registered before a
    // talker, by updating existing listener port parameters.
    await _updateExistingListeners(
      contextIdentifier: contextIdentifier,
      talkerPort: port,
      talkerValue: talkerValue,
      eventSource: eventSource
    )
  }

  private func _updateExistingListeners(
    contextIdentifier: MAPContextIdentifier,
    talkerPort port: P,
    talkerValue: any MSRPTalkerValue,
    eventSource: EventSource
  ) async {
    guard let talkerParticipant = try? findParticipant(port: port) else { return }

    // _propagateListenerDeclarationToTalker() will examine all listeners and
    // return the merged declaration type, so there is no need to do this
    // within the apply() loop
    guard let mergedDeclarationType = try? await _propagateListenerDeclarationToTalker(
      contextIdentifier: contextIdentifier,
      listenerPort: nil,
      declarationType: nil,
      isNew: false,
      eventSource: eventSource,
      talkerRegistration: (talkerParticipant, talkerValue)
    )
    else { return }

    // however, after processing existing listener registrations for a talker
    // that didn't exist previously, we do need to update port parameters on
    // each talker port that matches the listener stream ID
    await apply(for: contextIdentifier) { participant in
      guard let listenerRegistration = await _findListenerRegistration(
        for: talkerValue.streamID,
        participant: participant
      ) else {
        return
      }

      // verify talker still exists (guard against race with talker departure)
      guard let currentTalker = await _findTalkerRegistration(
        for: talkerValue.streamID,
        participant: talkerParticipant
      ), currentTalker.streamID == talkerValue.streamID else {
        _logger
          .debug(
            "MSRP: talker \(talkerValue.streamID) no longer exists, skipping port parameter update"
          )
        return
      }

      try? await _updatePortParameters(
        port: participant.port,
        streamID: listenerRegistration.0.streamID,
        mergedDeclarationType: mergedDeclarationType,
        talkerRegistration: (talkerParticipant, currentTalker)
      )
    }
  }

  private func _mergeListener(
    declarationType firstDeclarationType: MSRPDeclarationType,
    with secondDeclarationType: MSRPDeclarationType?
  ) -> MSRPDeclarationType {
    let mergedDeclarationType: MSRPDeclarationType

    // 35.2.4.4.3 Merge Listener Declarations
    switch firstDeclarationType {
    case .listenerReady:
      switch secondDeclarationType {
      case nil:
        fallthrough
      case .listenerReady:
        mergedDeclarationType = .listenerReady
      case .listenerReadyFailed:
        fallthrough
      case .listenerAskingFailed:
        fallthrough
      default:
        mergedDeclarationType = .listenerReadyFailed
      }
    case .listenerReadyFailed:
      mergedDeclarationType = .listenerReadyFailed
    case .listenerAskingFailed:
      switch secondDeclarationType {
      case .listenerReady:
        fallthrough
      case .listenerReadyFailed:
        mergedDeclarationType = .listenerReadyFailed
      case nil:
        fallthrough
      case .listenerAskingFailed:
        fallthrough
      default:
        mergedDeclarationType = .listenerAskingFailed
      }
    default:
      preconditionFailure("\(firstDeclarationType) is not a listener declaration")
    }

    _logger
      .trace(
        "MSRP: merge \(firstDeclarationType) + \(String(describing: secondDeclarationType)) -> \(mergedDeclarationType)"
      )

    return mergedDeclarationType
  }

  private func _findListenerRegistration(
    for streamID: MSRPStreamID,
    participant: Participant<MSRPApplication>
  ) async -> (MSRPListenerValue, MSRPAttributeSubtype)? {
    guard let listenerAttribute = await participant.findAttribute(
      attributeType: MSRPAttributeType.listener.rawValue,
      matching: .matchAnyIndex(streamID.index)
    ) else { return nil }

    guard let listenerValue = listenerAttribute.1 as? MSRPListenerValue,
          let attributeSubtype = listenerAttribute.0,
          let listenerDeclarationType = MSRPAttributeSubtype(rawValue: attributeSubtype)
    else {
      return nil
    }

    return (listenerValue, listenerDeclarationType)
  }

  private func _findTalkerRegistration(
    for streamID: MSRPStreamID,
    participant: Participant<MSRPApplication>
  ) async -> (any MSRPTalkerValue)? {
    // TalkerFailed takes precedence over TalkerAdvertise per spec
    if let value = await participant.findAttribute(
      attributeType: MSRPAttributeType.talkerFailed.rawValue,
      matching: .matchAnyIndex(streamID.index)
    ) {
      value.1 as? (any MSRPTalkerValue)
    } else if let value = await participant.findAttribute(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchAnyIndex(streamID.index)
    ) {
      value.1 as? (any MSRPTalkerValue)
    } else {
      nil
    }
  }

  private func _findTalkerRegistration(
    for streamID: MSRPStreamID
  ) async -> TalkerRegistration? {
    var talkerRegistration: TalkerRegistration?

    await apply { participant in
      guard let participantTalker = await _findTalkerRegistration(
        for: streamID,
        participant: participant
      ), talkerRegistration == nil else {
        return
      }
      talkerRegistration = (participant, participantTalker)
    }

    return talkerRegistration
  }

  private func _mergeListenerDeclarations(
    contextIdentifier: MAPContextIdentifier,
    port: P?,
    declarationType: MSRPDeclarationType?,
    talkerRegistration: TalkerRegistration,
    isJoin: Bool
  ) async throws -> MSRPDeclarationType? {
    var mergedDeclarationType = isJoin ? declarationType : nil
    let streamID = talkerRegistration.1.streamID
    var listenerCount = mergedDeclarationType != nil ? 1 : 0

    // collect listener declarations from all other ports and merge declaration type
    await apply(for: contextIdentifier) { participant in
      // exclude registering or leaving port
      guard participant.port != port else { return }

      // exclude talker port
      guard participant.port != talkerRegistration.0.port else { return }

      for listenerAttribute in await participant.findAllAttributes(
        attributeType: MSRPAttributeType.listener.rawValue,
        matching: .matchAnyIndex(streamID.id)
      ) {
        guard let declarationType = try? MSRPDeclarationType(attributeSubtype: listenerAttribute
          .attributeSubtype)
        else { continue }
        if mergedDeclarationType == nil {
          mergedDeclarationType = declarationType
        } else {
          mergedDeclarationType = _mergeListener(
            declarationType: declarationType,
            with: mergedDeclarationType
          )
        }
        listenerCount += 1
      }
    }

    precondition(mergedDeclarationType == nil || listenerCount > 0)

    if talkerRegistration.1 is MSRPTalkerFailedValue, listenerCount > 0 {
      mergedDeclarationType = .listenerAskingFailed
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
      do {
        try await bridge.register(
          macAddress: talkerRegistration.dataFrameParameters.destinationAddress,
          vlan: talkerRegistration.dataFrameParameters.vlanIdentifier,
          on: [port]
        )
      } catch {
        _logger
          .debug(
            "MSRP: failed to register FDB entries for \(talkerRegistration.dataFrameParameters): \(error)"
          )
        throw error
      }
    } else {
      _logger.debug("MSRP: deregistering FDB entries for \(talkerRegistration.dataFrameParameters)")
      try? await bridge.deregister(
        macAddress: talkerRegistration.dataFrameParameters.destinationAddress,
        vlan: talkerRegistration.dataFrameParameters.vlanIdentifier,
        from: [port]
      )
    }
  }

  private func _findActiveTalkers(
    participant: Participant<MSRPApplication<P>>
  ) async -> Set<MSRPTalkerAdvertiseValue> {
    // Find all active talkers by querying listeners on this port and finding their corresponding
    // talkers
    await Set(participant.findAttributes(
      attributeType: MSRPAttributeType.listener.rawValue,
      matching: .matchAny
    ).asyncCompactMap {
      guard let attributeSubtype = $0.0,
            let attributeSubtype = MSRPAttributeSubtype(rawValue: attributeSubtype),
            attributeSubtype == .ready || attributeSubtype == .readyFailed else { return nil }

      let listener = $0.1 as! MSRPListenerValue
      guard let talkerRegistration = await _findTalkerRegistration(for: listener.streamID),
            let talkerAdvertise = talkerRegistration.1 as? MSRPTalkerAdvertiseValue
      else { return nil }
      return talkerAdvertise
    })
  }

  private func _updateOperIdleSlope(
    port: P,
    portState: MSRPPortState<P>,
    streamID: MSRPStreamID,
    declarationType: MSRPDeclarationType?,
    talkerRegistration: any MSRPTalkerValue
  ) async throws {
    guard let controller, let bridge = controller.bridge as? any MSRPAwareBridge<P> else {
      return
    }

    guard let participant = try? findParticipant(port: port) else {
      _logger.error("MSRP: failed to find participant for port \(port)")
      return
    }

    var talkers = await _findActiveTalkers(participant: participant)

    // Remove the specific talker stream that is the subject of this
    // registration or deregistration; we will add it back conditionally
    // based on the presented declaration type
    if let index = talkers.firstIndex(where: { $0.streamID == streamID }) {
      talkers.remove(at: index)
    }

    // Only add it back if there are active listeners for this talker
    if let talkerRegistration = talkerRegistration as? MSRPTalkerAdvertiseValue,
       declarationType == .listenerReady || declarationType == .listenerReadyFailed
    {
      talkers.insert(talkerRegistration)
    }

    var streams = [SRclassID: [MSRPTSpec]]()

    for talker in talkers {
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

    do {
      try await bridge.adjustCreditBasedShaper(
        application: self,
        port: port,
        portState: portState,
        streams: streams
      )
    } catch {
      _logger.error("MSRP: failed to adjust credit based shaper: \(error)")
      throw error
    }
  }

  private func _updatePortParameters(
    port: P,
    streamID: MSRPStreamID,
    mergedDeclarationType: MSRPDeclarationType?,
    talkerRegistration: TalkerRegistration
  ) async throws {
    let portState = try withPortState(port: port) {
      if mergedDeclarationType == .listenerReady || mergedDeclarationType == .listenerReadyFailed {
        $0.register(streamID: streamID)
      } else {
        $0.deregister(streamID: streamID)
      }
      return $0
    }

    _logger
      .info(
        "MSRP: updating port parameters for port \(port) streamID \(streamID) declaration type \(String(describing: mergedDeclarationType)) talker \(talkerRegistration.0.port):\(talkerRegistration.1)"
      )

    do {
      if mergedDeclarationType == .listenerReady || mergedDeclarationType == .listenerReadyFailed {
        // increase (if necessary) bandwidth first before updating dynamic reservation entries
        try await _updateOperIdleSlope(
          port: port,
          portState: portState,
          streamID: streamID,
          declarationType: mergedDeclarationType,
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
          declarationType: mergedDeclarationType,
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

  private func _propagateListenerDeclarationToTalker(
    contextIdentifier: MAPContextIdentifier,
    listenerPort port: P?,
    declarationType: MSRPDeclarationType?,
    isNew: Bool,
    eventSource: EventSource,
    talkerRegistration: TalkerRegistration
  ) async throws -> MSRPDeclarationType? {
    // point-to-point talker registrations should not come from the same port as the listener
    if let port, port.isPointToPoint, talkerRegistration.0.port == port {
      _logger
        .error(
          "MSRP: talker registration \(talkerRegistration) found on listener port \(port), ignoring"
        )
      return nil
    }

    // TL;DR: propagate merged Listener declarations to _talker_ port
    guard let mergedDeclarationType = try await _mergeListenerDeclarations(
      contextIdentifier: contextIdentifier,
      port: port,
      declarationType: declarationType,
      talkerRegistration: talkerRegistration,
      isJoin: true
    ) else { return nil }

    let streamID = talkerRegistration.1.streamID

    _logger
      .info(
        "MSRP: propagating listener declaration streamID \(streamID) declarationType \(declarationType != nil ? String(describing: declarationType!) : "<nil>") -> \(mergedDeclarationType) to participant \(talkerRegistration.0)"
      )

    try await talkerRegistration.0.join(
      attributeType: MSRPAttributeType.listener.rawValue,
      attributeSubtype: mergedDeclarationType.attributeSubtype!.rawValue,
      attributeValue: MSRPListenerValue(streamID: streamID),
      isNew: isNew,
      eventSource: .map
    )

    return mergedDeclarationType
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
    guard let talkerRegistration = await _findTalkerRegistration(for: streamID) else {
      // no listener attribute propagation if no talker (35.2.4.4.1)
      // this is an expected race condition - listener arrives before talker
      // when talker arrives, _updateExistingListeners() will process it
      _logger
        .debug(
          "MSRP: listener registration for stream \(streamID) received before talker, will be processed when talker arrives"
        )
      return
    }

    guard let mergedDeclarationType = try await _propagateListenerDeclarationToTalker(
      contextIdentifier: contextIdentifier,
      listenerPort: port,
      declarationType: declarationType,
      isNew: isNew,
      eventSource: eventSource,
      talkerRegistration: talkerRegistration
    ) else { return }

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
    guard eventSource != .map else {
      _logger
        .trace(
          "MSRP: ignoring join indication for attribute \(attributeType) isNew \(isNew) subtype \(String(describing: attributeSubtype)) value \(attributeValue) source \(eventSource) port \(port)"
        )
      // don't recursively invoke MAP
      throw MRPError.doNotPropagateAttribute
    }

    try await _checkAsCapable(port: port, attributeType: attributeType, isJoin: true)

    switch attributeType {
    case .talkerAdvertise:
      let attributeValue = (attributeValue as! MSRPTalkerAdvertiseValue)
      try await _onRegisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        talkerValue: attributeValue,
        failureInformation: nil,
        isNew: isNew,
        eventSource: eventSource
      )
    case .talkerFailed:
      let attributeValue = (attributeValue as! MSRPTalkerFailedValue)
      try await _onRegisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        talkerValue: attributeValue,
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
      else {
        // attributeSubtype of 0 (ignore) returns nil - this is expected, skip this event
        throw MRPError.doNotPropagateAttribute
      }
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
      try withPortState(port: port) { portState in
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
    talkerValue: any MSRPTalkerValue,
    eventSource: EventSource
  ) async throws {
    let streamID = talkerValue.streamID

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
      guard participant.port != port else { return } // don't propagate to source port

      // If this participant has active listeners, propagate a leave back to the talker
      if let listenerRegistration = await _findListenerRegistration(
        for: streamID,
        participant: participant
      ) {
        try await talkerParticipant.leave(
          attributeType: MSRPAttributeType.listener.rawValue,
          attributeSubtype: listenerRegistration.1.rawValue,
          attributeValue: listenerRegistration.0,
          eventSource: .map
        )

        try await _updatePortParameters(
          port: participant.port,
          streamID: streamID,
          mergedDeclarationType: nil,
          talkerRegistration: (talkerParticipant, talkerValue)
        )
      }

      // 35.2.4.3: If no Talker attributes are registered for a StreamID then
      // no Talker attributes for that StreamID will be declared on any other
      // port of the Bridge. i.e. implement as ordinary attribute propagation
      try await participant.leave(
        attributeType: talkerValue.declarationType!.attributeType.rawValue,
        attributeSubtype: nil,
        attributeValue: talkerValue,
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
    // On receipt of a MAD_Leave.indication for a Listener Declaration, if the
    // StreamID of the Declaration matches a Stream that the Talker is
    // transmitting, then the Talker shall stop the transmission for this
    // Stream, if it is transmitting.
    guard let talkerRegistration = await _findTalkerRegistration(for: streamID) else {
      return
    }

    // TL;DR: propagate merged Listener declarations to _talker_ port
    let mergedDeclarationType = try await _mergeListenerDeclarations(
      contextIdentifier: contextIdentifier,
      port: port,
      declarationType: declarationType,
      talkerRegistration: talkerRegistration,
      isJoin: false
    )

    _logger
      .info(
        "MSRP: deregister attach indication from port \(port) streamID \(streamID) declarationType \(declarationType) -> \(mergedDeclarationType != nil ? String(describing: mergedDeclarationType!) : "<nil>") to participant \(talkerRegistration.0)"
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

    guard eventSource != .map else {
      _logger
        .trace(
          "MSRP: ignoring leave indication for attribute \(attributeType) subtype \(String(describing: attributeSubtype)) value \(attributeValue) source \(eventSource) port \(port)"
        )
      // don't recursively invoke MAP
      throw MRPError.doNotPropagateAttribute
    }

    try await _checkAsCapable(port: port, attributeType: attributeType, isJoin: false)

    switch attributeType {
    case .talkerAdvertise:
      try await _onDeregisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        talkerValue: (attributeValue as! MSRPTalkerAdvertiseValue),
        eventSource: eventSource
      )
    case .talkerFailed:
      try await _onDeregisterStreamIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        talkerValue: (attributeValue as! MSRPTalkerFailedValue),
        eventSource: eventSource
      )
    case .listener:
      guard let declarationType = try? MSRPDeclarationType(attributeSubtype: attributeSubtype)
      else {
        // attributeSubtype of 0 (ignore) returns nil - this is expected, skip this event
        throw MRPError.doNotPropagateAttribute
      }
      try await _onDeregisterAttachIndication(
        contextIdentifier: contextIdentifier,
        port: port,
        streamID: (attributeValue as! MSRPListenerValue).streamID,
        declarationType: declarationType,
        eventSource: eventSource
      )
    case .domain:
      let domain = (attributeValue as! MSRPDomainValue)
      try withPortState(port: port) { portState in
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

    domain = try withPortState(port: participant.port) { portState in
      portState.getDomain(for: srClassID, defaultSRPVid: _srPVid)
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

  private var _numberOfRegisteredTalkerAttributes: Int {
    get async {
      var numberOfTalkerAttributes = 0

      await apply { participant in
        numberOfTalkerAttributes += await participant.findAttributes(
          attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
          matching: .matchAny
        ).count

        numberOfTalkerAttributes += await participant.findAttributes(
          attributeType: MSRPAttributeType.talkerFailed.rawValue,
          matching: .matchAny
        ).count
      }

      return numberOfTalkerAttributes
    }
  }

  private var _isMaxTalkerAttributesRegistered: Bool {
    get async {
      guard _maxTalkerAttributes > 0 else { return false }
      return await _numberOfRegisteredTalkerAttributes >= _maxTalkerAttributes
    }
  }
}

#if canImport(FlyingFox)
extension MSRPApplication: RestApiApplication {
  func registerRestApiHandlers(for httpServer: HTTPServer) async throws {
    let msrpHandler = MSRPHandler(application: self)

    await httpServer.appendRoute("GET /api/avb/msrp", to: msrpHandler)
    await httpServer.appendRoute("GET /api/avb/msrp/*", to: msrpHandler)
  }
}
#endif
