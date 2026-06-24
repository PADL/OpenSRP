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

import AsyncExtensions
import BinaryParsing
import IEEE802
import Logging
import Synchronization
#if RestAPI
import FlyingFox
#endif

public let MSRPEtherType: UInt16 = 0x22EA

public struct MSRPApplicationFlags: OptionSet, Sendable {
  public typealias RawValue = UInt8

  public let rawValue: RawValue

  public init(rawValue: RawValue) { self.rawValue = rawValue }

  public static let forceAvbCapable = Self(rawValue: 1 << 0)
  public static let configureEgressQueues = Self(rawValue: 1 << 1)
  public static let ignoreAsCapable = Self(rawValue: 1 << 2)
  public static let talkerPruning = Self(rawValue: 1 << 3)
  public static let configureIngressQueues = Self(rawValue: 1 << 4)

  public static let defaultFlags = Self([.ignoreAsCapable])
}

protocol MSRPAwareBridge<P>: Bridge where P: AVBPort {
  func configureEgressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) async throws

  func unconfigureEgressQueues(
    port: P
  ) async throws

  func configureIngressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) async throws

  // Unlike egress (MQPRIO) queues, which can be torn down by qdisc handle alone,
  // DCBNL APP entries are keyed by their (selector, protocol, priority) tuple and the
  // switch only clears a PCP mapping if the priority matches. The same parameters used
  // to configure must therefore be supplied to recompute the exact entries to delete.
  func unconfigureIngressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
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
  var stpPortState: STPPortState // blocked (non-Forwarding) ports don't propagate (35.1.3.1)
  var isForwarding: Bool { stpPortState == .forwarding }
  var streamEpochs = [MSRPStreamID: UInt32]()
  // last Domain value declared per SR class, so we only re-emit on an actual change (the Domain
  // attribute is declared New, which the Applicant does not suppress)
  var declaredDomains = [SRclassID: MSRPDomainValue]()
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
    stpPortState = port.stpPortState
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

public actor MSRPApplication<P: AVBPort>: BaseApplication, BaseApplicationEventObserver, Sendable,
  BaseApplicationContextObserver, CustomStringConvertible where P == P
{
  private typealias TalkerRegistration = (Participant<MSRPApplication>, any MSRPTalkerValue)

  // for now, we only operate in the Base Spanning Tree Context
  public nonisolated var nonBaseContextsSupported: Bool { false }

  public nonisolated var validAttributeTypes: ClosedRange<AttributeType> {
    MSRPAttributeType.validAttributeTypes
  }

  public nonisolated var groupAddress: EUI48 { IndividualLANScopeGroupAddress }

  public nonisolated var etherType: UInt16 { MSRPEtherType }

  public nonisolated var protocolVersion: ProtocolVersion { MSRPProtocolVersion.v0.rawValue }

  public nonisolated var hasAttributeListLength: Bool { true }

  let _controller: Weak<MRPController<P>>

  public nonisolated var controller: MRPController<P>? { _controller.object }

  var _participants: [MAPContextIdentifier: Set<Participant<MSRPApplication<P>>>] = [:]
  let _logger: Logger
  let _latencyMaxFrameSize: UInt16
  let _queues: [SRclassID: UInt]

  let _srPVid: VLAN
  let _deltaBandwidths: [SRclassID: Int]
  let _maxTalkerAttributes: Int
  let _flags: MSRPApplicationFlags

  fileprivate let _maxFanInPorts: Int
  fileprivate let _maxSRClass: SRclassID
  fileprivate var _portStates: [P.ID: MSRPPortState<P>] = [:]
  fileprivate let _mmrp: MMRPApplication<P>?
  fileprivate var _priorityMapNotificationTask: Task<(), Error>?

  // Desired declarations + reservations for one stream
  private struct StreamPlan {
    let streamID: MSRPStreamID
    var boundTalker: TalkerRegistration?
    var talkerDeclarations = [(participant: Participant<MSRPApplication>, failure: MSRPFailure?)]()
    var mergedListener: MSRPDeclarationType? // propagated towards talker
    var listenerPorts =
      [(participant: Participant<MSRPApplication>, declarationType: MSRPDeclarationType)]()
  }

  private struct Reservation: Equatable {
    let declarationType: MSRPDeclarationType?
    let talker: any MSRPTalkerValue

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.declarationType == rhs.declarationType &&
        lhs.talker.dataFrameParameters == rhs.talker.dataFrameParameters &&
        lhs.talker.tSpec == rhs.talker.tSpec &&
        lhs.talker.priorityAndRank == rhs.talker.priorityAndRank
    }
  }

  private var _pendingStreams = Set<MSRPStreamID>()
  private var _streamUpdateTask: Task<(), Never>?
  private var _reservations: [P.ID: [MSRPStreamID: Reservation]] = [:]

  // Convenience accessors for flags
  fileprivate nonisolated var _forceAvbCapable: Bool { _flags.contains(.forceAvbCapable) }
  fileprivate nonisolated var _configureEgressQueues: Bool {
    _flags.contains(.configureEgressQueues)
  }

  fileprivate nonisolated var _configureIngressQueues: Bool {
    _flags.contains(.configureIngressQueues)
  }

  nonisolated var _ignoreAsCapable: Bool { _flags.contains(.ignoreAsCapable) }
  fileprivate nonisolated var _talkerPruning: Bool { _flags.contains(.talkerPruning) }

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
    _priorityMapNotificationTask = Task { [weak self] in
      guard let self, let controller = self.controller,
            let bridge = controller.bridge as? any MSRPAwareBridge<P> else { return }

      try? await _observePriorityMapNotifications(bridge: bridge, controller: controller)
    }
  }

  // Workaround for Swift 6.3 SIL verification crash: the optimizer incorrectly
  // specializes the witness_method through the existential cast, producing a
  // type mismatch between concrete and generic associated types. Extracting the
  // loop into a separate generic method keeps the types consistent.
  private func _observePriorityMapNotifications<B: MSRPAwareBridge>(
    bridge: B,
    controller: MRPController<P>
  ) async throws where B.P == P {
    for try await notification in bridge.srClassPriorityMapNotifications {
      guard let port = try? await controller.port(with: notification.portID) else { continue }
      try? withPortState(port: port) { portState in
        portState.srClassPriorityMap = notification.map
      }
    }
  }

  deinit {
    _priorityMapNotificationTask?.cancel()
    _streamUpdateTask?.cancel()
  }

  @discardableResult
  func withPortState<T>(
    port: P,
    _ body: (_: inout MSRPPortState<P>) throws -> T
  ) throws -> T {
    if let index = _portStates.index(forKey: port.id) {
      return try body(&_portStates.values[index])
    } else {
      throw MRPError.portNotFound
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
      if _configureEgressQueues || _configureIngressQueues,
         port.isAvbCapable || _forceAvbCapable
      {
        if _configureEgressQueues {
          try? await bridge.unconfigureEgressQueues(port: port)
          try await bridge.configureEgressQueues(
            port: port,
            srClassPriorityMap: DefaultSRClassPriorityMap,
            queues: _queues,
            forceAvbCapable: _forceAvbCapable
          )
        }
        if _configureIngressQueues {
          // configureIngressQueues is ref-counted at the bridge and handles both per-port
          // ingress maps (e.g. 88E6390) and global maps shared across all ports (e.g.
          // 88E6352). No pre-clear is needed here (a blind per-port delete would tear down a
          // shared global map for the other member ports).
          //
          // Ingress (DCBNL) configuration is best-effort: kernels/switches without the DCBNL
          // priority-map migration return EOPNOTSUPP. A failure here must not abort port setup
          // (otherwise the port is left half-registered and re-notifications fail with
          // portAlreadyExists), so log and continue.
          do {
            try await bridge.configureIngressQueues(
              port: port,
              srClassPriorityMap: DefaultSRClassPriorityMap,
              queues: _queues,
              forceAvbCapable: _forceAvbCapable
            )
          } catch {
            _logger
              .error("MSRP: failed to configure ingress queues for port \(port): \(error)")
          }
        }
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

    for port in context {
      var portState = try MSRPPortState(msrp: self, port: port)
      if let srClassPriorityMap = srClassPriorityMap[port.id] {
        portState.srClassPriorityMap = srClassPriorityMap
      }
      _portStates[port.id] = portState
    }

    for port in context {
      _logger.debug("MSRP: declaring domains for port \(port)")
      try _declareDomains(port: port)
    }
  }

  func onContextUpdated(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext else { return }

    if !_forceAvbCapable {
      for port in context {
        guard let index = _portStates.index(forKey: port.id) else { continue }
        if _portStates.values[index].msrpPortEnabledStatus != port.isAvbCapable {
          _logger.info("MSRP: port \(port) changed isAvbCapable, now \(port.isAvbCapable)")
        }
        _portStates.values[index].msrpPortEnabledStatus = port.isAvbCapable
      }
    }

    // refresh spanning-tree state from the fresh port (a synchronous read, no actor hop); a
    // change is a topology change, so re-derive the active streams
    var stpChanged = false
    for port in context {
      guard let index = _portStates.index(forKey: port.id) else { continue }
      if _portStates.values[index].stpPortState != port.stpPortState {
        _logger.info("MSRP: port \(port) spanning-tree state now \(port.stpPortState)")
        _portStates.values[index].stpPortState = port.stpPortState
        stpChanged = true
      }
    }
    if stpChanged { _forceUpdateActiveStreams() }

    for port in context {
      _logger.debug("MSRP: re-declaring domains for port \(port)")
      try _declareDomains(port: port)
    }
  }

  // re-derive every stream with a registered talker or a programmed reservation; used when a
  // port's Forwarding state changes (the active topology, and thus propagation, has changed)
  private func _forceUpdateActiveStreams() {
    var streamIDs = Set(_reservations.values.flatMap { $0.keys })
    apply(for: MAPBaseSpanningTreeContext) { participant in
      for type in [MSRPAttributeType.talkerAdvertise, .talkerFailed] {
        for attr in participant.findAllAttributesUnchecked(
          attributeType: type.rawValue, matching: .matchAny, isolation: self
        ) where attr.isRegistered {
          if let talker = attr.attributeValue as? any MSRPTalkerValue {
            streamIDs.insert(talker.streamID)
          }
        }
      }
    }
    for streamID in streamIDs { _streamDidUpdate(streamID) }
  }

  func onContextRemoved(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext else { return }

    if _configureEgressQueues || _configureIngressQueues,
       let bridge = (controller?.bridge as? any MSRPAwareBridge<P>)
    {
      for port in context {
        guard port.isAvbCapable || _forceAvbCapable else { continue }
        if _configureEgressQueues {
          do {
            try await bridge.unconfigureEgressQueues(port: port)
          } catch {
            _logger.error("MSRP: failed to unconfigure queues for port \(port): \(error)")
          }
        }
        if _configureIngressQueues {
          do {
            try await bridge.unconfigureIngressQueues(
              port: port,
              srClassPriorityMap: DefaultSRClassPriorityMap,
              queues: _queues,
              forceAvbCapable: _forceAvbCapable
            )
          } catch {
            _logger
              .error("MSRP: failed to unconfigure ingress queues for port \(port): \(error)")
          }
        }
      }
    }

    for port in context {
      _logger.debug("MSRP: port \(port) disappeared, removing")
      _portStates.removeValue(forKey: port.id)
      // drop cached reservations so a later re-add reprograms the hardware
      _reservations[port.id] = nil
    }
  }

  public nonisolated var description: String {
    "MSRPApplication(controller: \(controller!))"
  }

  public nonisolated var name: String { "MSRP" }

  public nonisolated func deserialize(
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

  public nonisolated func makeNullValue(for attributeType: AttributeType) throws -> any Value {
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

  public nonisolated func hasAttributeSubtype(for attributeType: AttributeType) -> Bool {
    attributeType == MSRPAttributeType.listener.rawValue
  }

  public nonisolated func administrativeControl(for attributeType: AttributeType) throws
    -> AdministrativeControl
  {
    .normalParticipant
  }

  // 35.1.3.1: block a Talker Declaration until its SR-class VLAN is present on
  // the port. With the Talker held in MT the listener-side reservation (and its
  // MDB offload) isn't attempted before the VLAN exists in the VTU; the next
  // re-declaration registers it once the VLAN is there.
  public nonisolated func isRegistrationAllowed(
    for attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    on port: P
  ) -> Bool {
    guard attributeType == MSRPAttributeType.talkerAdvertise.rawValue ||
      attributeType == MSRPAttributeType.talkerFailed.rawValue,
      let talker = attributeValue as? any MSRPTalkerValue
    else {
      return true
    }
    return port.vlans.contains(talker.dataFrameParameters.vlanIdentifier)
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
  ) throws {
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

    try join(
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
  ) throws {
    guard let talkerRegistration = _findTalkerRegistration(for: streamID) else {
      throw MRPError.participantNotFound
    }
    let declarationType: MSRPDeclarationType = if talkerRegistration.1 is MSRPTalkerAdvertiseValue {
      .talkerAdvertise
    } else {
      .talkerFailed
    }
    try leave(
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
  ) throws {
    try apply { participant in
      if let port, port != participant.port { return }
      try join(
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
  ) throws {
    try apply { participant in
      if let port, port != participant.port { return }

      guard let listenerRegistration = _findListenerRegistration(
        for: streamID,
        participant: participant
      ) else { return }

      try leave(
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
  ) throws {
    let oppositeType: MSRPAttributeType = declarationType == .talkerAdvertise ? .talkerFailed :
      .talkerAdvertise

    let oppositeAttributes = participant.findAttributes(
      attributeType: oppositeType.rawValue,
      matching: .matchAnyIndex(streamID.index)
    )

    for (_, attributeValue) in oppositeAttributes {
      if eventSource == .map {
        try? participant.leave(
          attributeType: oppositeType.rawValue,
          attributeValue: attributeValue,
          eventSource: eventSource
        )
      } else {
        try? participant.deregister(
          attributeType: oppositeType.rawValue,
          attributeValue: attributeValue,
          eventSource: eventSource
        )
      }
    }
  }

  private func _shouldPruneTalkerDeclaration(
    port: P,
    talker: any MSRPTalkerValue
  ) async -> Bool {
    guard let portState = try? withPortState(port: port, { $0 }) else { return true }

    if _talkerPruning || portState.talkerPruning {
      if let mmrpParticipant = try? await _mmrp?.findParticipant(port: port),
         mmrpParticipant.findAttribute(
           attributeType: MMRPAttributeType.mac.rawValue,
           matching: .matchEqual(
             MMRPMACValue(macAddress: talker.dataFrameParameters.destinationAddress)
           )
         ) == nil
      {
        _logger.trace("MSRP: pruning talker stream \(talker.streamID) on port \(port)")
        return true
      }
    }
    if portState.talkerVlanPruning {
      guard port.vlans.contains(talker.dataFrameParameters.vlanIdentifier) else { return true }
    }

    return false
  }

  private func _isFanInPortLimitReached() -> Bool {
    if _maxFanInPorts == 0 {
      return false
    }

    var fanInCount = 0

    // calculate total number of ports with inbound reservations
    apply { participant in
      if participant.findAttribute(
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
    talker: MSRPTalkerAdvertiseValue,
    nominalBandwidth: Bool
  ) throws -> Int {
    guard let srClassID = portState
      .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
    else {
      return 0
    }

    let (_, bandwidthUsed) = try calculateBandwidthUsed(
      srClassID: srClassID,
      tSpec: talker.tSpec,
      maxFrameSize: _latencyMaxFrameSize,
      nominalBandwidth: nominalBandwidth
    )

    return bandwidthUsed
  }

  func _calculateBandwidthUsed(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    provisionalTalker: MSRPTalkerAdvertiseValue? = nil
  ) throws -> [SRclassID: Int] {
    var bandwidthUsed = [SRclassID: Int]()

    // Find all active talkers (those with listeners in ready or readyFailed state)
    var talkers = _findActiveTalkers(participant: participant)

    // Add provisional talker if provided (for bandwidth admission control check)
    if let provisionalTalker { talkers.insert(provisionalTalker) }

    for talker in talkers {
      guard let srClassID = portState
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
      else {
        continue
      }
      let bw = try _calculateBandwidthUsed(
        portState: portState,
        talker: talker,
        nominalBandwidth: false
      )
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
  ) throws -> Bool {
    let port = participant.port
    let provisionalTalker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParameters,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 0 // or this
    )

    let bandwidthUsed = try _calculateBandwidthUsed(
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
    talker: any MSRPTalkerValue
  ) throws {
    let port = participant.port
    do {
      guard let portState = try? withPortState(port: port, { $0 }) else {
        throw MSRPFailure(systemID: port.systemID, failureCode: .insufficientBridgeResources)
      }

      guard portState.msrpPortEnabledStatus else {
        _logger.error("MSRP: port \(port) is not enabled")
        throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      if let existingTalkerRegistration = _findTalkerRegistration(
        for: talker.streamID,
        participant: participant
      ), existingTalkerRegistration.dataFrameParameters != talker.dataFrameParameters {
        _logger
          .error(
            "MSRP: stream \(talker.streamID) is already registered on port \(port) with \(talker.dataFrameParameters)"
          )
        throw MSRPFailure(systemID: port.systemID, failureCode: .streamIDAlreadyInUse)
      }

      // TODO: should we check explicitly for false
      guard let srClassID = portState
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority),
        portState.srpDomainBoundaryPort[srClassID] != true
      else {
        _logger
          .error("MSRP: port \(port) is a SRP domain boundary port for \(talker.priorityAndRank)")
        throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      guard !_isFanInPortLimitReached() else {
        _logger.error("MSRP: fan in port limit reached")
        throw MSRPFailure(systemID: port.systemID, failureCode: .fanInPortLimitReached)
      }

      guard talker.tSpec.maxIntervalFrames != 0 else {
        _logger.error("MSRP: MaxIntervalFrames cannot be zero")
        throw MSRPFailure(systemID: port.systemID, failureCode: .insufficientBridgeResources)
      }

      // maxFrameSize does not include preamble, IEEE 802.3 header,
      // Priority/VID tag, CRC, interframe gap
      guard calcFrameSize(talker.tSpec) <= port.mtu else {
        _logger.error("MSRP: MaxFrameSize \(talker.tSpec.maxFrameSize) is too large for media")
        throw MSRPFailure(systemID: port.systemID, failureCode: .maxFrameSizeTooLargeForMedia)
      }

      guard try _checkAvailableBandwidth(
        participant: participant,
        portState: portState,
        streamID: talker.streamID,
        dataFrameParameters: talker.dataFrameParameters,
        tSpec: talker.tSpec,
        priorityAndRank: talker.priorityAndRank
      )
      else {
        _logger
          .error("MSRP: bandwidth limit exceeded for stream \(talker.streamID) on port \(port)")
        throw MSRPFailure(systemID: port.systemID, failureCode: .insufficientBandwidth)
      }
    } catch let error as MSRPFailure {
      throw error
    } catch {
      _logger.error("MSRP: cannot bridge talker: generic error \(error)")
      throw MSRPFailure(systemID: port.systemID, failureCode: .outOfMSRPResources)
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
  ) -> (MSRPListenerValue, MSRPAttributeSubtype)? {
    guard let listenerAttribute = participant.findAttribute(
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
  ) -> (any MSRPTalkerValue)? {
    // TalkerFailed takes precedence over TalkerAdvertise per spec
    if let value = participant.findAttribute(
      attributeType: MSRPAttributeType.talkerFailed.rawValue,
      matching: .matchAnyIndex(streamID.index)
    ) {
      value.1 as? (any MSRPTalkerValue)
    } else if let value = participant.findAttribute(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchAnyIndex(streamID.index)
    ) {
      value.1 as? (any MSRPTalkerValue)
    } else {
      nil
    }
  }

  private func _findTalkerRegistration(
    for streamID: MSRPStreamID,
    requireForwarding: Bool = false
  ) -> TalkerRegistration? {
    var talkerRegistration: TalkerRegistration?

    apply { participant in
      // a talker registered on a blocked (non-Forwarding) port is "blocked" (35.1.3.1) and
      // must not be selected as the bound talker: its declaration is not forwarded out the
      // other ports and no reservation is programmed from it (10.3). Registration is still
      // allowed on any port regardless of state (8.4); only propagation is gated.
      if requireForwarding, _portStates[participant.port.id]?.isForwarding != true { return }

      guard let participantTalker = _findTalkerRegistration(
        for: streamID,
        participant: participant
      ) else {
        return
      }
      if talkerRegistration == nil {
        talkerRegistration = (participant, participantTalker)
      } else if talkerRegistration!.1 is MSRPTalkerFailedValue,
                participantTalker is MSRPTalkerAdvertiseValue
      {
        // Prefer talkerAdvertise over talkerFailed: the talkerAdvertise
        // registration is on the ingress port closest to the talker source,
        // which is where listener declarations should be propagated
        talkerRegistration = (participant, participantTalker)
      }
    }

    return talkerRegistration
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
          flags: .dynamicReservation,
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
  ) -> Set<MSRPTalkerAdvertiseValue> {
    // Find all active talkers by querying listeners on this port and finding their corresponding
    // talkers
    Set(participant.findAttributes(
      attributeType: MSRPAttributeType.listener.rawValue,
      matching: .matchAny
    ).compactMap {
      guard let attributeSubtype = $0.0,
            let attributeSubtype = MSRPAttributeSubtype(rawValue: attributeSubtype),
            attributeSubtype == .ready || attributeSubtype == .readyFailed else { return nil }

      let listener = $0.1 as! MSRPListenerValue
      guard let talkerRegistration = _findTalkerRegistration(for: listener.streamID),
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

    var talkers = _findActiveTalkers(participant: participant)

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
    case .talkerAdvertise, .talkerFailed:
      let talkerValue = (attributeValue as! any MSRPTalkerValue)
      guard await !_isMaxTalkerAttributesRegistered else {
        _logger
          .info(
            "MSRP: ignoring talker \(talkerValue.streamID) on \(port): max talker attributes registered"
          )
        throw MRPError.doNotPropagateAttribute
      }
      // mutual exclusion: clear the opposite talker registration on the source port
      if eventSource == .peer {
        try _enforceTalkerMutualExclusion(
          participant: findParticipant(for: contextIdentifier, port: port),
          declarationType: talkerValue.declarationType!,
          streamID: talkerValue.streamID,
          eventSource: .peer
        )
      }
      _streamDidUpdate(talkerValue.streamID)
    case .listener:
      _streamDidUpdate((attributeValue as! MSRPListenerValue).streamID)
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

  func _streamDidUpdate(_ streamID: MSRPStreamID) {
    _pendingStreams.insert(streamID)
    guard _streamUpdateTask == nil else { return }
    _streamUpdateTask = Task { [weak self] in await self?._applyPendingStreamUpdates() }
  }

  private func _applyPendingStreamUpdates() async {
    while let streamID = _pendingStreams.popFirst() {
      do { try await _applyStreamPlan(_makeStreamPlan(streamID)) }
      catch { _logger.error("MSRP: recompute failed for stream \(streamID): \(error)") }
    }
    _streamUpdateTask = nil
  }

  // note: this function must remain synchronous to avoid reentrancy issues
  private func _makeStreamPlan(_ streamID: MSRPStreamID) -> StreamPlan {
    var plan = StreamPlan(streamID: streamID)

    // the bound talker must be on a Forwarding port: a talker registered on a blocked port
    // propagates nothing (35.1.3.1, 10.3)
    guard let boundTalker = _findTalkerRegistration(
      for: streamID, requireForwarding: true
    ) else { return plan }
    plan.boundTalker = boundTalker

    let failed = boundTalker.1 as? MSRPTalkerFailedValue

    apply(for: MAPBaseSpanningTreeContext) { participant in
      // a blocked (non-Forwarding) port propagates nothing — no declaration is forwarded out
      // it and no reservation is programmed on it (35.1.3.1, 10.3)
      guard _portStates[participant.port.id]?.isForwarding ?? false else { return }

      // a listener reserves on its own port using its own declaration (a failed talker
      // forces askingFailed); .ignore subtypes don't reserve
      if let listener = _findListenerRegistration(for: streamID, participant: participant),
         let ownDeclaration = MSRPDeclarationType(attributeSubtype: listener.1)
      {
        plan.listenerPorts
          .append((participant, failed != nil ? .listenerAskingFailed : ownDeclaration))

        // merge registered listeners toward the talker, excluding its own port
        if participant.port != boundTalker.0.port {
          plan.mergedListener = _mergeListener(
            declarationType: ownDeclaration,
            with: plan.mergedListener
          )
        }
      }

      // never declare the talker back towards the source
      guard participant.port != boundTalker.0.port,
            _findTalkerRegistration(for: streamID, participant: participant) == nil else { return }

      if let failed {
        plan.talkerDeclarations
          .append((
            participant,
            MSRPFailure(systemID: failed.systemID, failureCode: failed.failureCode)
          ))
      } else {
        do {
          try _canBridgeTalker(participant: participant, talker: boundTalker.1)
          plan.talkerDeclarations.append((participant, nil))
        } catch let error as MSRPFailure {
          plan.talkerDeclarations.append((participant, error))
        } catch {}
      }
    }

    // a failed talker forces the aggregate listener declaration toward it to askingFailed
    // (mergedListener is non-nil iff a listener merged toward the talker — excludes its own port)
    if failed != nil, plan.mergedListener != nil {
      plan.mergedListener = .listenerAskingFailed
    }

    return plan
  }

  private func _applyStreamPlan(_ plan: StreamPlan) async throws {
    let streamID = plan.streamID
    guard let boundTalker = plan.boundTalker else {
      try await _withdrawStream(streamID)
      return
    }

    var declaredTalkerPorts = Set<P.ID>()

    for (participant, failure) in plan.talkerDeclarations {
      if await _shouldPruneTalkerDeclaration(port: participant.port, talker: boundTalker.1) {
        continue // pruned: the sweep below withdraws any existing declaration
      }

      var latency = boundTalker.1.accumulatedLatency
      do {
        let l = try await participant.port
          .getPortTcMaxLatency(for: boundTalker.1.priorityAndRank.dataFramePriority)
        guard l >= 0 else { throw MRPError.portLatencyIsNegative(l) }
        latency += UInt32(l)
      } catch { latency += 500 }

      let declarationType: MSRPDeclarationType = failure == nil ? .talkerAdvertise : .talkerFailed
      try? _enforceTalkerMutualExclusion(
        participant: participant, declarationType: declarationType, streamID: streamID,
        eventSource: .map
      )

      if let failure {
        try participant.join(
          attributeType: MSRPAttributeType.talkerFailed.rawValue,
          attributeValue: boundTalker.1.makeFailed(accumulatedLatency: latency, failure: failure),
          isNew: false, eventSource: .map
        )
      } else {
        try participant.join(
          attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
          attributeValue: boundTalker.1.makeAdvertise(accumulatedLatency: latency),
          isNew: false, eventSource: .map
        )
      }

      declaredTalkerPorts.insert(participant.port.id)
    }

    // withdraw talker declarations no longer desired
    apply(for: MAPBaseSpanningTreeContext) { participant in
      guard !declaredTalkerPorts.contains(participant.port.id) else { return }
      _leaveDeclaredAttributes(
        participant,
        streamID: streamID,
        types: [.talkerAdvertise, .talkerFailed]
      )
    }

    let listenerValue = MSRPListenerValue(streamID: streamID)
    let desiredListenerPort: P.ID? = plan.mergedListener != nil ? boundTalker.0.port.id : nil

    if let merged = plan.mergedListener {
      try boundTalker.0.join(
        attributeType: MSRPAttributeType.listener.rawValue,
        attributeSubtype: merged.attributeSubtype!.rawValue,
        attributeValue: listenerValue, isNew: false, eventSource: .map
      )
    }

    // withdraw listener declarations toward any talker other than the current bound one
    apply(for: MAPBaseSpanningTreeContext) { participant in
      guard participant.port.id != desiredListenerPort else { return }
      _leaveDeclaredAttributes(participant, streamID: streamID, types: [.listener])
    }

    // pending streams updated; let the next drain perform reservations
    if _pendingStreams.contains(streamID) { return }

    let keep = Set(plan.listenerPorts.map(\.participant.port.id))

    for (participant, declarationType) in plan.listenerPorts {
      let desired = Reservation(declarationType: declarationType, talker: boundTalker.1)

      // idempotency: only touch the kernel when the reservation actually changed
      if _reservations[participant.port.id]?[streamID] != desired {
        try await _updatePortParameters(
          port: participant.port, streamID: streamID,
          mergedDeclarationType: declarationType, talkerRegistration: boundTalker
        )
      }
      _reservations[participant.port.id, default: [:]][streamID] = desired
    }

    for (portID, talker) in _reservationsToWithdraw(streamID, keeping: keep) {
      if let participant = _participant(for: portID) {
        try? await _updatePortParameters(
          port: participant.port, streamID: streamID,
          mergedDeclarationType: nil, talkerRegistration: (participant, talker)
        )
      }
      _clearReservation(portID: portID, streamID: streamID)
    }
  }

  // No talker registered: withdraw every reservation and our own declarations for the stream.
  private func _withdrawStream(_ streamID: MSRPStreamID) async throws {
    for (portID, talker) in _reservationsToWithdraw(streamID, keeping: []) {
      if let participant = _participant(for: portID) {
        try? await _updatePortParameters(
          port: participant.port, streamID: streamID,
          mergedDeclarationType: nil, talkerRegistration: (participant, talker)
        )
      }
      _clearReservation(portID: portID, streamID: streamID)
    }

    apply(for: MAPBaseSpanningTreeContext) { participant in
      _leaveDeclaredAttributes(
        participant, streamID: streamID, types: [.talkerAdvertise, .talkerFailed, .listener]
      )
    }
  }

  // leave our own declared attributes (of the given types) for a stream on one port.
  // Any declared attribute is left, including one that is also registered: leaving with
  // eventSource .map withdraws our Applicant declaration without clearing the Registrar,
  // which is what stops us declaring toward a port that now registers the stream itself.
  private func _leaveDeclaredAttributes(
    _ participant: Participant<MSRPApplication>, streamID: MSRPStreamID,
    types: [MSRPAttributeType]
  ) {
    for type in types {
      for attr in participant.findAllAttributesUnchecked(
        attributeType: type.rawValue, matching: .matchAnyIndex(streamID.id), isolation: self
      ) where attr.isDeclared {
        try? participant.leave(
          attributeType: type.rawValue, attributeValue: attr.attributeValue, eventSource: .map
        )
      }
    }
  }

  private func _clearReservation(portID: P.ID, streamID: MSRPStreamID) {
    _reservations[portID]?[streamID] = nil
    if _reservations[portID]?.isEmpty == true { _reservations[portID] = nil }
  }

  private func _reservationsToWithdraw(
    _ streamID: MSRPStreamID, keeping: Set<P.ID>
  ) -> [(P.ID, any MSRPTalkerValue)] {
    _reservations.compactMap { portID, streams in
      guard let applied = streams[streamID], !keeping.contains(portID) else { return nil }
      return (portID, applied.talker)
    }
  }

  private func _participant(for portID: P.ID) -> Participant<MSRPApplication>? {
    var found: Participant<MSRPApplication>?
    apply(for: MAPBaseSpanningTreeContext) { participant in
      if participant.port.id == portID { found = participant }
    }
    return found
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
      fallthrough
    case .talkerFailed:
      fallthrough
    case .listener:
      _streamDidUpdate((attributeValue as! any MSRPStreamIDRepresentable).streamID)
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
  ) throws {
    // Domain is not propagated by MSRP MAP (35.2.4) and is never "blocked" (35.1.3.1) — it is a
    // local per-port announcement. Re-declare only when the value actually changed, since a port
    // event can fire many context updates and the Domain is declared New (not Applicant-suppressed).
    let toDeclare: MSRPDomainValue? = try withPortState(port: participant.port) { portState in
      guard let domain = portState.getDomain(for: srClassID, defaultSRPVid: _srPVid) else {
        _logger
          .warning(
            "MSRP: not declaring domain for SR class \(srClassID) as no priority mapping found"
          )
        return nil
      }
      guard portState.declaredDomains[srClassID] != domain else { return nil }
      portState.declaredDomains[srClassID] = domain
      return domain
    }

    guard let domain = toDeclare else { return }
    _logger.info("MSRP: declaring domain \(domain)")
    try participant.join(
      attributeType: MSRPAttributeType.domain.rawValue,
      attributeValue: domain,
      isNew: true,
      eventSource: .application
    )
  }

  fileprivate nonisolated var _allSRClassIDs: [SRclassID] {
    Array((_maxSRClass.rawValue...SRclassID.A.rawValue).map { SRclassID(rawValue: $0)! })
  }

  private func _declareDomains(port: P) throws {
    let participant = try findParticipant(port: port)
    for srClassID in _allSRClassIDs {
      try _declareDomain(srClassID: srClassID, on: participant)
    }
  }

  private var _numberOfRegisteredTalkerAttributes: Int {
    get async {
      var numberOfTalkerAttributes = 0

      apply { participant in
        numberOfTalkerAttributes += participant.findAttributes(
          attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
          matching: .matchAny
        ).count

        numberOfTalkerAttributes += participant.findAttributes(
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

#if RestAPI
extension MSRPApplication: RestApiApplication {
  func registerRestApiHandlers(for httpServer: HTTPServer) async throws {
    let msrpHandler = MSRPHandler(application: self)

    await httpServer.appendRoute("GET /api/avb/msrp", to: msrpHandler)
    await httpServer.appendRoute("GET /api/avb/msrp/*", to: msrpHandler)
  }
}
#endif
