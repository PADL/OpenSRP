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
import OrderedCollections
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
  // Registrar leaves immediately on a received Leave (Avnu ProAV Bridge §9.2); on by default,
  // clear it to fall back to the base 802.1Q leavetimer when interoperating with peers that
  // do not use the Avnu LeaveTime
  public static let leaveImmediate = Self(rawValue: 1 << 5)
  // Disable 802.3x flow control (clause 31 PAUSE) on every AVB-capable port at
  // setup, unconditionally, as required of AVB ports by IEEE 802.1BA-2011 §6.4 and
  // as comparable AVB switches do. On by default; clear it to leave the port's
  // autonegotiated flow control untouched.
  public static let disableFlowControl = Self(rawValue: 1 << 6)
  // Install an MDB entry on the bound Talker's ingress port (in addition to the egress
  // Listener ports), so a "secure" switch (e.g. Marvell) admits the stream's destination
  // address + PCP only from the Talker's port and drops it on a boundary/non-Talker port.
  public static let configureIngressMdb = Self(rawValue: 1 << 7)

  public static let defaultFlags =
    Self([.ignoreAsCapable, .leaveImmediate, .disableFlowControl])
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

  // bridge's own System ID (priority + base MAC) for a Talker Failed FailedInfo (35.2.2.8.7)
  var systemID: MSRPSystemID { get async }
}

private let DefaultSRClassPriorityMap: SRClassPriorityMap = [.A: .CA, .B: .EE]
private let DefaultDeltaBandwidths: [SRclassID: Int] = [.A: 75, .B: 0]

struct MSRPPortState<P: AVBPort>: Sendable {
  var mediaType: MSRPPortMediaType { .accessControlPort }
  var msrpPortEnabledStatus: Bool
  var stpPortState: STPPortState // blocked (non-Forwarding) ports don't propagate (35.1.3.1)
  var isForwarding: Bool { stpPortState == .forwarding }
  var streamEpochs = [MSRPStreamID: ContinuousClock.Instant]()
  // last Domain value declared per SR class, so we only re-emit on an actual change (the Domain
  // attribute is declared New, which the Applicant does not suppress)
  var declaredDomains = [SRclassID: MSRPDomainValue]()
  var srpDomainBoundaryPort: [SRclassID: Bool]
  var srpClassVID: [SRclassID: VLAN]
  // priorities with PFC enabled (34.5): an SR class mapped to one is always a boundary port
  var pfcEnabledPriorities: Set<SRclassPriority> = []
  // Avnu Table 6-5 (boundary-port SR priority regeneration override) is not applied here. The
  // regeneration is a per-port PCP->PCP table in the switch, and while the mv88e6xxx hardware can
  // do it, there is no userspace API to program it: the DCB app table (DCB_APP_SEL_PCP) maps a
  // priority to a *queue*, not to a regenerated priority. So it belongs behind a future kernel
  // interface, not this daemon; we only detect the boundary (srpDomainBoundaryPort).
  var neighborProtocolVersion: MSRPProtocolVersion { .v0 }
  // TODO: make these configurable
  var talkerPruning: Bool { false }
  var talkerVlanPruning: Bool { false }
  var srClassPriorityMap = SRClassPriorityMap()
  // class-independent per-hop latency (35.2.2.8.6 b/c/d) cached per port; nil until a real PTP
  // reading (the provisional 800 ns over-estimate is never stored). Cleared on flap/STP so it
  // re-samples.
  var portTcMaxLatency: Int?
  // per-stream reported-latency guarantee first declared on this port (35.2.2.8.6); lives here so
  // it is dropped with the port state on removal.
  var configuredLatency = [MSRPStreamID: UInt32]()

  // drop the cached per-hop latency on a link change (flap/STP) so the next recompute re-samples
  // gPTP meanLinkDelay. Per-stream guarantees survive for the reservation's life (35.2.2.8.6):
  // a topology-driven latency increase must trip code 7, not silently re-baseline.
  mutating func invalidate() {
    portTcMaxLatency = nil
  }

  func reverseMapSrClassPriority(priority: SRclassPriority) -> SRclassID? {
    srClassPriorityMap.first(where: { $0.value == priority })?.key
  }

  mutating func register(streamID: MSRPStreamID) {
    // record the first-reservation instant only; re-registration on later recomputes must not
    // reset the stream's age, or preemption ordering (youngest-first) would be unstable
    if streamEpochs[streamID] == nil { streamEpochs[streamID] = P.now }
  }

  mutating func deregister(streamID: MSRPStreamID) {
    streamEpochs[streamID] = nil
  }

  // age in whole seconds since the stream was reserved (diagnostic); 0 if not reserved
  func getStreamAge(for streamID: MSRPStreamID) -> UInt32 {
    guard let epoch = streamEpochs[streamID] else { return 0 }
    return UInt32(clamping: (P.now - epoch).components.seconds)
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

  init(application: MSRPApplication<P>, port: P) throws {
    let isAvbCapable = port.isAvbCapable || application._forceAvbCapable
    msrpPortEnabledStatus = isAvbCapable
    stpPortState = port.stpPortState
    srpDomainBoundaryPort = .init(uniqueKeysWithValues: application._allSRClassIDs.map { (
      $0,
      !isAvbCapable
    ) })
    srpClassVID = .init(uniqueKeysWithValues: application._allSRClassIDs.map { (
      $0,
      application._srPVid
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
  // bridge System ID cached from the (async) bridge base MAC for the synchronous recompute path
  fileprivate var _bridgeSystemID: MSRPSystemID?

  // Desired declarations + reservations for one stream
  private struct StreamPlan {
    let streamID: MSRPStreamID
    var boundTalker: TalkerRegistration?
    var talkerDeclarations = [(participant: Participant<MSRPApplication>, failure: MSRPFailure?)]()
    var mergedListener: MSRPDeclarationType? // propagated towards talker
    var listenerPorts =
      [(participant: Participant<MSRPApplication>, declarationType: MSRPDeclarationType)]()
    // lower-importance streams this one displaces by reserving (Avnu §9.1); re-evaluated by
    // their own recompute, where they find themselves over-budget and declare Failed
    var displacedStreams = Set<MSRPStreamID>()
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

  // the ingress-port FDB entry installed for a stream when .configureIngressMdb is set. Keyed by
  // stream so it is installed once for the bound Talker and torn down only when the Talker leaves
  // (not on Listener churn); records the port + frame parameters so a Talker that moves ports
  // relocates the entry.
  private struct FDBEntry: Equatable {
    let portID: P.ID
    let dataFrameParameters: MSRPDataFrameParameters
  }

  private var _pendingStreams = OrderedSet<MSRPStreamID>()
  private var _streamUpdateTask: Task<(), Never>?
  private var _reservations: [P.ID: [MSRPStreamID: Reservation]] = [:]
  private var _ingressFdbEntries: [MSRPStreamID: FDBEntry] = [:]

  // Convenience accessors for flags
  fileprivate nonisolated var _forceAvbCapable: Bool { _flags.contains(.forceAvbCapable) }
  fileprivate nonisolated var _configureEgressQueues: Bool {
    _flags.contains(.configureEgressQueues)
  }

  fileprivate nonisolated var _configureIngressQueues: Bool {
    _flags.contains(.configureIngressQueues)
  }

  fileprivate nonisolated var _disableFlowControl: Bool {
    _flags.contains(.disableFlowControl)
  }

  fileprivate nonisolated var _configureIngressMdb: Bool {
    _flags.contains(.configureIngressMdb)
  }

  nonisolated var _ignoreAsCapable: Bool { _flags.contains(.ignoreAsCapable) }
  public nonisolated var registrarLeaveImmediate: Bool { _flags.contains(.leaveImmediate) }

  // 5.4.4 the Periodic Transmission state machine (10.7.10) is specifically
  // excluded from MSRP (Avnu ProAV Bridge §9.1)
  public nonisolated var usePeriodicTransmission: Bool { false }
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

  // IEEE 802.1BA-2011 §6.4: AVB ports do not use 802.3x flow control. Disable PAUSE
  // once, at port setup (not per stream), so a received PAUSE can never stall
  // reserved egress. Best effort and idempotent: an unsupported port is logged once
  // and skipped. The kernel-side fix (mv88e6xxx mac_link_up honoring the resolved
  // pause) is required for this to take effect on that hardware.
  private func _setupFlowControl(port: P) async {
    guard _disableFlowControl, port.isAvbCapable || _forceAvbCapable else { return }
    do {
      try await port.setFlowControl(false)
    } catch MRPError.notSupported {
      _logger
        .warning(
          "MSRP: flow control not configurable on port \(port); IEEE 802.1BA-2011 §6.4 PAUSE suppression not enforced"
        )
    } catch {
      _logger.error("MSRP: failed to disable flow control on port \(port): \(error)")
    }
  }

  func onContextAdded(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    guard contextIdentifier == MAPBaseSpanningTreeContext else { return }

    var srClassPriorityMap = [P.ID: SRClassPriorityMap]()
    var pfcEnabledPriorities = [P.ID: Set<SRclassPriority>]()

    guard let bridge = (controller?.bridge as? any MSRPAwareBridge<P>) else {
      _logger.error("MSRP: bridge is not MSRP-aware, cannot declare domains")
      return
    }
    _bridgeSystemID = await bridge.systemID

    for port in context {
      await _setupFlowControl(port: port)

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
      // best-effort; folded into the boundary-port state below (fetched here, in the awaiting
      // loop, so the state-building loop stays synchronous)
      pfcEnabledPriorities[port.id] = await (try? port.pfcEnabledPriorities) ?? []
    }

    for port in context {
      var portState = try MSRPPortState(application: self, port: port)
      if let srClassPriorityMap = srClassPriorityMap[port.id] {
        portState.srClassPriorityMap = srClassPriorityMap
      }
      // 802.1Q 34.5/35.2.1.4: an SR class whose priority has PFC enabled (mutually exclusive with
      // the credit-based shaper) makes this an SRP domain boundary port for that class
      if let pfc = pfcEnabledPriorities[port.id] {
        portState.pfcEnabledPriorities = pfc
        for (srClassID, priority) in portState.srClassPriorityMap where pfc.contains(priority) {
          portState.srpDomainBoundaryPort[srClassID] = true
        }
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
          _portStates.values[index].invalidate() // link flapped: re-sample PTP latency
        }
        _portStates.values[index].msrpPortEnabledStatus = port.isAvbCapable
      }
    }

    // refresh spanning-tree state from the fresh port (a synchronous read, no actor hop); a change
    // is a topology change, so invalidate the port's latency state here (the single place STP
    // clears it) and re-derive the active streams
    var stpChanged = false
    for port in context {
      guard let index = _portStates.index(forKey: port.id) else { continue }
      if _portStates.values[index].stpPortState != port.stpPortState {
        _logger.info("MSRP: port \(port) spanning-tree state now \(port.stpPortState)")
        _portStates.values[index].stpPortState = port.stpPortState
        _portStates.values[index].invalidate()
        stpChanged = true
      }
    }
    if stpChanged {
      // a topology change can move a port's worst-case path latency (35.2.2.8.6): the recompute
      // below re-samples per-hop latency fresh and fails a stream whose reported latency rose above
      // its guarantee.
      _forceUpdateActiveStreams()
    }

    // A port whose link was down at startup was skipped for the priority-map fetch (it was not yet
    // AVB capable). Now that it may have come up, fetch the map so it can declare SR domains: the
    // mqprio qdisc exists independent of link state, but no TC notification fires on link-up, so
    // without this a late-linking port would keep an empty map and never declare its domains.
    if let bridge = (controller?.bridge as? any MSRPAwareBridge<P>) {
      _bridgeSystemID = await bridge.systemID
      var fetchedMaps = [P.ID: SRClassPriorityMap]()
      for port in context where port.isAvbCapable || _forceAvbCapable {
        guard let index = _portStates.index(forKey: port.id),
              _portStates.values[index].srClassPriorityMap.isEmpty,
              let map = try? await bridge.getSRClassPriorityMap(port: port) else { continue }
        fetchedMaps[port.id] = map
      }
      for (portID, map) in fetchedMaps {
        guard let index = _portStates.index(forKey: portID) else { continue }
        _portStates.values[index].srClassPriorityMap = map
      }
    }

    for port in context {
      _logger.debug("MSRP: re-declaring domains for port \(port)")
      try _declareDomains(port: port)
    }
  }

  // re-derive every stream with a registered talker or a programmed reservation; used when a
  // port's Forwarding state changes (the active topology, and thus propagation, has changed)
  private func _forceUpdateActiveStreams() {
    var streamIDs = Set(_reservations.values.flatMap(\.keys))
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
    for streamID in streamIDs {
      _streamDidUpdate(streamID)
    }
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

    let vanishedPortIDs = Set(context.map(\.id))
    for port in context {
      _logger.debug("MSRP: port \(port) disappeared, removing")
      _portStates.removeValue(forKey: port.id)
      // drop cached reservations so a later re-add reprograms the hardware
      _reservations[port.id] = nil
    }
    // the kernel drops FDB entries on a vanished port; forget any ingress entry we tracked for a
    // Talker on one so the cache does not go stale
    if !vanishedPortIDs.isEmpty {
      _ingressFdbEntries = _ingressFdbEntries.filter { !vanishedPortIDs.contains($0.value.portID) }
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

  // Don't coalesce the Domain attribute: its FirstValue increment chain (Class B -> Class A)
  // forms a multi-value vector that some non-compliant peers fail to expand, seeing only the
  // Class B FirstValue. Emit each SR class as its own single-value vector.
  public nonisolated func coalesceVectors(for attributeType: AttributeType) -> Bool {
    attributeType != MSRPAttributeType.domain.rawValue
  }

  public nonisolated func administrativeControl(for attributeType: AttributeType) throws
    -> AdministrativeControl
  {
    AdministrativeControl()
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
    case .listenerAskingFailed, .listenerReady, .listenerReadyFailed:
      throw MRPError.invalidMSRPDeclarationType
    }

    let attributeType = declarationType.attributeType
    let oppositeAttributeType = attributeType.oppositeAttributeType!

    // 35.2.6: at most one Talker declaration per StreamID per port. A type change (e.g.
    // Advertise->Failed) behaves as if the old declaration was withdrawn before the new one,
    // so leave the opposite declared Talker type first.
    try apply(for: MAPBaseSpanningTreeContext) { participant in
      let replacing = _leaveDeclaredAttributes(
        participant, streamID: streamID,
        types: [oppositeAttributeType], eventSource: .application
      )
      try participant.join(
        attributeType: attributeType.rawValue,
        attributeValue: attributeValue,
        isNew: !replacing,
        eventSource: .application
      )
    }
  }

  // On receipt of a DEREGISTER_STREAM.request the MSRP Participant shall issue
  // a MAD_Leave.request service primitive (10.2, 10.3) with the attribute_type
  // set to the Declaration Type currently associated with the StreamID. The
  // attribute_value parameter shall carry the StreamID and other values that
  // were in the associated REGISTER_STREAM.request primitive.
  public func deregisterStream(
    streamID: MSRPStreamID
  ) throws {
    // DEREGISTER_STREAM.request (35.2.3.1.3): leave the locally declared Talker attribute
    let wasDeclared = apply(for: MAPBaseSpanningTreeContext) { participant in
      _leaveDeclaredAttributes(
        participant, streamID: streamID,
        types: [.talkerAdvertise, .talkerFailed], eventSource: .application
      )
    }.reduce(false) { $0 || $1 }
    guard wasDeclared else { throw MRPError.participantNotFound }
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
    guard declarationType.attributeType == .listener else {
      throw MRPError.invalidMSRPDeclarationType
    }
    try apply { participant in
      if let port, port != participant.port { return }
      // 35.2.6: a Declaration Type change for an existing Listener declaration replaces it
      // (isNew false drives Participant.join's subtype-replacement path)
      let alreadyDeclared = participant.findAllAttributesUnchecked(
        attributeType: MSRPAttributeType.listener.rawValue,
        matching: .matchAnyIndex(streamID.id), isolation: self
      ).contains { $0.isDeclared }
      try participant.join(
        attributeType: MSRPAttributeType.listener.rawValue,
        attributeSubtype: declarationType.attributeSubtype?.rawValue,
        attributeValue: MSRPListenerValue(streamID: streamID),
        isNew: !alreadyDeclared,
        eventSource: .application
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
    // DEREGISTER_ATTACH.request (35.2.3.1.7): leave the locally declared Listener attribute
    apply { participant in
      if let port, port != participant.port { return }
      _leaveDeclaredAttributes(
        participant, streamID: streamID, types: [.listener], eventSource: .application
      )
    }
  }

  public func periodic(for contextIdentifier: MAPContextIdentifier? = nil) async throws {
    // not invoked: usePeriodicTransmission is false (5.4.4 excludes MSRP)
  }
}

extension MSRPApplication {
  // 35.2.6: at most one Talker declaration type per StreamID per port. A peer indication for
  // one type supersedes the opposite, so deregister the opposite *registered* (Registrar) Talker
  // attribute on the source port. (The local-declaration counterpart is _leaveDeclaredAttributes.)
  private func _deregisterOppositeTalkerRegistration(
    participant: Participant<MSRPApplication>,
    declarationType: MSRPDeclarationType,
    streamID: MSRPStreamID
  ) {
    guard let oppositeType = declarationType.attributeType.oppositeAttributeType else { return }
    for (_, attributeValue) in participant.findAttributes(
      attributeType: oppositeType.rawValue,
      matching: .matchAnyIndex(streamID.index)
    ) {
      try? participant.deregister(
        attributeType: oppositeType.rawValue,
        attributeValue: attributeValue,
        eventSource: .peer
      )
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
    // 802.1Q 35.2.2.8.5: the Rank bit reset (rank == false) is Emergency and
    // outranks the bit set (Non-emergency); Avnu §9.1 preempts in favour of
    // the Rank-reset stream
    if lhs.priorityAndRank.rank != rhs.priorityAndRank.rank {
      return !lhs.priorityAndRank.rank
    }

    // same rank: the older stream (earlier reservation instant) is more important; an unregistered
    // (provisional) stream is the youngest. Finally tie-break on lower StreamID.
    let lhsEpoch = portState.streamEpochs[lhs.streamID]
    let rhsEpoch = portState.streamEpochs[rhs.streamID]
    if lhsEpoch == rhsEpoch {
      return lhs.streamID.id < rhs.streamID.id
    }
    guard let lhsEpoch else { return false } // lhs youngest → less important
    guard let rhsEpoch else { return true } // rhs youngest → lhs more important
    return lhsEpoch < rhsEpoch
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

    // exactly filling the configured limit is admissible (35.2.4.2/35.2.4.3): used <= limit
    return Double(aggregateBandwidth) <= Double(port.linkSpeed) * Double(bandwidthLimit) /
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
      nominalBandwidth: nominalBandwidth
    )

    return bandwidthUsed
  }

  // bandwidth (kbps) per SR class consumed by a set of reserving talkers, or nil if a mapped SR
  // class cannot be sized (e.g. has no measurement interval) — callers must then fail closed
  private func _bandwidthUsed(
    portState: MSRPPortState<P>,
    talkers: Set<MSRPTalkerAdvertiseValue>
  ) -> [SRclassID: Int]? {
    try? talkers.reduce(into: [SRclassID: Int]()) { bandwidthUsed, talker in
      // a talker whose priority maps to no SR class consumes no reservable bandwidth
      guard let srClassID = portState
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
      else { return }
      bandwidthUsed[srClassID, default: 0] += try calculateBandwidthUsed(
        srClassID: srClassID, tSpec: talker.tSpec, nominalBandwidth: false
      ).1
    }
  }

  // true if every SR class is within its (cumulative) bandwidth limit for this set of talkers;
  // false (fail closed) if their bandwidth cannot be computed
  private func _talkersFit(
    port: P, portState: MSRPPortState<P>, talkers: Set<MSRPTalkerAdvertiseValue>
  ) -> Bool {
    guard let bandwidthUsed = _bandwidthUsed(portState: portState, talkers: talkers) else {
      return false
    }
    return SRclassID.allCases.allSatisfy { srClassID in
      _checkAvailableBandwidth(
        port: port, portState: portState, srClassID: srClassID, bandwidthUsed: bandwidthUsed
      )
    }
  }

  // Avnu ProAV Bridge §9.1 preemption. Given the candidate talkers for a port's bandwidth, return
  // the subset that remains admitted. Admission is greedy in most-important-first order: each
  // stream is admitted only if it still fits alongside the more-important streams already admitted.
  // This is equivalent to cancelling the youngest (least important) streams until the rest fit and
  // then re-admitting any that need not have been cancelled ("if a stream that would have been
  // cancelled need not be, then it should not be"), but expressed as a single pass. Because more
  // important streams are always considered first, the result is order-independent and a preempted
  // stream can never preempt its preemptor back.
  private func _admittedStreamIDs(
    port: P, portState: MSRPPortState<P>, candidates: Set<MSRPTalkerAdvertiseValue>
  ) -> Set<MSRPStreamID> {
    guard !_talkersFit(port: port, portState: portState, talkers: candidates) else {
      return Set(candidates.map(\.streamID))
    }
    let mostImportantFirst = candidates.sorted {
      _compareStreamImportance(port: port, portState: portState, $0, $1)
    }
    let admitted = mostImportantFirst
      .reduce(into: Set<MSRPTalkerAdvertiseValue>()) { kept, candidate in
        if _talkersFit(port: port, portState: portState, talkers: kept.union([candidate])) {
          kept.insert(candidate)
        }
      }
    return Set(admitted.map(\.streamID))
  }

  // the candidate talkers for a port's bandwidth: those currently reserving, with `provisional`
  // substituted in for its own stream (admission control for a not-yet-reserved or changed talker)
  private func _candidateTalkers(
    participant: Participant<MSRPApplication>,
    provisional: MSRPTalkerAdvertiseValue
  ) -> Set<MSRPTalkerAdvertiseValue> {
    _findReservedTalkers(participant: participant)
      .filter { $0.streamID != provisional.streamID }
      .union([provisional])
  }

  // FailedInfo BridgeID (35.2.2.8.7): the bridge's own System ID, or the zero sentinel when it is
  // not yet cached (before onContextAdded, or on a non-MSRP-aware bridge). Zero is deliberate: a
  // port-MAC-derived guess would be a plausible-but-wrong BridgeID that could mislead a Listener,
  // whereas zero reads unambiguously as "System ID unknown".
  private var _systemID: MSRPSystemID { _bridgeSystemID ?? MSRPSystemID(id: 0) }

  // Admission control with preemption (Avnu §9.1): nil if the talker is admitted on the port,
  // otherwise the failure to declare — streamPreemptedByHigherRank when a more important stream
  // displaced it, insufficientBandwidth when it simply does not fit.
  private func _admissionFailure(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    talker: any MSRPTalkerValue
  ) -> MSRPFailure? {
    let port = participant.port
    let provisional = talker.makeAdvertise(accumulatedLatency: 0)
    let candidates = _candidateTalkers(participant: participant, provisional: provisional)
    let admitted = _admittedStreamIDs(port: port, portState: portState, candidates: candidates)
    if admitted.contains(talker.streamID) { return nil }
    // it was only preempted if it could have fit on its own; a stream that exceeds the budget even
    // alone simply does not fit, and no amount of preemption would admit it
    let fitsAlone = _talkersFit(port: port, portState: portState, talkers: [provisional])
    let lostToHigher = fitsAlone && candidates.contains { other in
      other.streamID != talker.streamID && admitted.contains(other.streamID) &&
        _compareStreamImportance(port: port, portState: portState, other, provisional)
    }
    return MSRPFailure(
      systemID: _systemID,
      failureCode: lostToHigher ? .streamPreemptedByHigherRank : .insufficientBandwidth
    )
  }

  // the lower-importance streams currently reserving on a port that `talker` (about to reserve)
  // displaces under Avnu §9.1 — they must re-evaluate and declare Failed on their own recompute
  private func _displacedStreamIDs(
    participant: Participant<MSRPApplication>,
    portState: MSRPPortState<P>,
    talker: any MSRPTalkerValue
  ) -> Set<MSRPStreamID> {
    let provisional = talker.makeAdvertise(accumulatedLatency: 0)
    let candidates = _candidateTalkers(participant: participant, provisional: provisional)
    let admitted = _admittedStreamIDs(
      port: participant.port, portState: portState, candidates: candidates
    )
    // reserved streams that are no longer admitted (excluding this talker itself)
    return Set(_findReservedTalkers(participant: participant).map(\.streamID))
      .subtracting(admitted)
      .subtracting([talker.streamID])
  }

  private func _canBridgeTalker(
    participant: Participant<MSRPApplication>,
    talker: any MSRPTalkerValue
  ) throws {
    let port = participant.port
    do {
      guard let portState = try? withPortState(port: port, { $0 }) else {
        throw MSRPFailure(systemID: _systemID, failureCode: .insufficientBridgeResources)
      }

      guard portState.msrpPortEnabledStatus else {
        _logger.error("MSRP: port \(port) is not enabled")
        throw MSRPFailure(systemID: _systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      if let existingTalkerRegistration = _findTalkerRegistration(
        for: talker.streamID,
        participant: participant
      ), MSRPTalkerFirstValue(existingTalkerRegistration) != MSRPTalkerFirstValue(talker) {
        _logger
          .error(
            "MSRP: stream \(talker.streamID) is already registered on port \(port) with a different FirstValue"
          )
        throw MSRPFailure(
          systemID: _systemID,
          failureCode: .changeInFirstValueForRegisteredStreamID
        )
      }

      // 35.2.2.8.3: SRP only supports multicast or locally-administered destination addresses
      let firstOctet = talker.dataFrameParameters.destinationAddress[0]
      let isMulticast = (firstOctet & 0x01) != 0
      let isLocallyAdministered = (firstOctet & 0x02) != 0
      guard isMulticast || isLocallyAdministered else {
        _logger.error(
          "MSRP: stream \(talker.streamID) destination address is not multicast/local"
        )
        throw MSRPFailure(systemID: _systemID, failureCode: .useDifferentDestinationAddress)
      }

      // 35.2.2.8.3: only one Stream is allowed per destination_address
      if _destinationAddressInUse(
        byOtherStream: talker.streamID,
        address: talker.dataFrameParameters.destinationAddress
      ) {
        _logger.error(
          "MSRP: stream \(talker.streamID) destination address already in use by another stream"
        )
        throw MSRPFailure(
          systemID: _systemID, failureCode: .streamDestinationAddressAlreadyInUse
        )
      }

      // a priority that maps to no SR class is a distinct failure (35.2.2.8.7 code 13)
      // from an SR-class-capable port that is a domain boundary (code 8)
      guard let srClassID = portState
        .reverseMapSrClassPriority(priority: talker.priorityAndRank.dataFramePriority)
      else {
        _logger.error(
          "MSRP: priority \(talker.priorityAndRank) is not an SR class priority on port \(port)"
        )
        throw MSRPFailure(
          systemID: _systemID, failureCode: .requestedPriorityIsNotAnSRClassPriority
        )
      }

      guard portState.srpDomainBoundaryPort[srClassID] != true else {
        _logger
          .error("MSRP: port \(port) is a SRP domain boundary port for \(talker.priorityAndRank)")
        throw MSRPFailure(systemID: _systemID, failureCode: .egressPortIsNotAvbCapable)
      }

      guard !_isFanInPortLimitReached() else {
        _logger.error("MSRP: fan in port limit reached")
        throw MSRPFailure(systemID: _systemID, failureCode: .fanInPortLimitReached)
      }

      // A zero MaxIntervalFrames is a degenerate (zero-bandwidth) TSpec; reject it rather than
      // enter a pointless reservation. Table 35-6 defines no code for an invalid MaxIntervalFrames
      // (unlike MaxFrameSize, code 14), so .insufficientBridgeResources is the least-bad generic;
      // it still propagates as a Talker Failed toward the Listener.
      guard talker.tSpec.maxIntervalFrames != 0 else {
        _logger.error("MSRP: MaxIntervalFrames cannot be zero")
        throw MSRPFailure(systemID: _systemID, failureCode: .insufficientBridgeResources)
      }

      // MaxFrameSize (35.2.2.8.4) and port.mtu both exclude media framing overhead, so compare
      // directly; calcFrameSize()'s overhead is only for bandwidth, not this media-fit test
      guard UInt(talker.tSpec.maxFrameSize) <= port.mtu else {
        _logger.error("MSRP: MaxFrameSize \(talker.tSpec.maxFrameSize) is too large for media")
        throw MSRPFailure(systemID: _systemID, failureCode: .maxFrameSizeTooLargeForMedia)
      }

      if let failure = _admissionFailure(
        participant: participant, portState: portState, talker: talker
      ) {
        _logger.error(
          "MSRP: stream \(talker.streamID) not admitted on port \(port): \(failure.failureCode)"
        )
        throw failure
      }
    } catch let error as MSRPFailure {
      throw error
    } catch {
      _logger.error("MSRP: cannot bridge talker: generic error \(error)")
      throw MSRPFailure(systemID: _systemID, failureCode: .outOfMSRPResources)
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

  // Install (or relocate) the ingress-port FDB entry for a stream on the bound Talker's port, so a
  // "secure" switch admits the stream's destination address + PCP from the Talker port. Idempotent:
  // it only touches the kernel when the port or frame parameters change, and the entry is removed
  // by
  // _removeIngressFdbEntry when the Talker leaves -- not on Listener churn.
  private func _updateIngressFdbEntry(
    streamID: MSRPStreamID,
    boundTalker: TalkerRegistration
  ) async throws {
    guard _configureIngressMdb else { return }
    guard let controller, let bridge = controller.bridge as? any MMRPAwareBridge<P> else { return }

    // Only manage the entry for a Talker Advertise on a point-to-point source link. A Talker Failed
    // has no reservation to admit; and on a shared source link a co-located Listener's egress
    // reservation shares this exact (port, MAC, VLAN) kernel entry (non-refcounted), so managing
    // our
    // own there would fight its teardown -- per-port secure admission is a point-to-point concept
    // anyway. Drop any entry left over from a Talker that has since moved to such a port.
    guard boundTalker.1 is MSRPTalkerAdvertiseValue, boundTalker.0.port.isPointToPoint else {
      await _removeIngressFdbEntry(streamID: streamID)
      return
    }

    let desired = FDBEntry(
      portID: boundTalker.0.port.id,
      dataFrameParameters: boundTalker.1.dataFrameParameters
    )
    guard _ingressFdbEntries[streamID] != desired else { return }

    // the Talker moved ports or changed its frame parameters: remove the stale entry first
    await _removeIngressFdbEntry(streamID: streamID)

    _logger
      .debug(
        "MSRP: adding dynamic reservation ingress MDB entry for \(desired.dataFrameParameters) on \(boundTalker.0.port)"
      )
    do {
      try await bridge.register(
        macAddress: desired.dataFrameParameters.destinationAddress,
        vlan: desired.dataFrameParameters.vlanIdentifier,
        flags: .dynamicReservation,
        on: [boundTalker.0.port]
      )
    } catch {
      // leave the cache empty so the next recompute retries (idempotency re-adds it)
      _ingressFdbEntries[streamID] = nil
      _logger
        .error(
          "MSRP: failed to add dynamic reservation ingress MDB entry for \(desired.dataFrameParameters) on \(boundTalker.0.port): \(error)"
        )
      throw error
    }
    _ingressFdbEntries[streamID] = desired
  }

  private func _removeIngressFdbEntry(streamID: MSRPStreamID) async {
    guard let entry = _ingressFdbEntries[streamID] else { return }
    // deregister before dropping the cache record, so a failed lookup/deregister does not silently
    // orphan a live kernel entry (the port-disappeared cleanup drops the cache separately, where
    // the
    // kernel has already removed the entry)
    if let controller, let bridge = controller.bridge as? any MMRPAwareBridge<P>,
       let port = _participant(for: entry.portID)?.port
    {
      _logger
        .debug(
          "MSRP: removing dynamic reservation ingress MDB entry for \(entry.dataFrameParameters) on \(port)"
        )
      try? await bridge.deregister(
        macAddress: entry.dataFrameParameters.destinationAddress,
        vlan: entry.dataFrameParameters.vlanIdentifier,
        from: [port]
      )
    }
    _ingressFdbEntries[streamID] = nil
  }

  // 35.2.2.8.3: a destination_address may be used by at most one Stream. Returns true if any
  // registered Talker for a *different* StreamID already uses this destination address.
  private func _destinationAddressInUse(
    byOtherStream streamID: MSRPStreamID, address: EUI48
  ) -> Bool {
    var inUse = false
    apply(for: MAPBaseSpanningTreeContext) { participant in
      for type in [MSRPAttributeType.talkerAdvertise, .talkerFailed] {
        for attr in participant.findAllAttributesUnchecked(
          attributeType: type.rawValue, matching: .matchAny, isolation: self
        ) where attr.isRegistered {
          guard let talker = attr.attributeValue as? any MSRPTalkerValue,
                talker.streamID != streamID,
                _isEqualMacAddress(talker.dataFrameParameters.destinationAddress, address)
          else { continue }
          inUse = true
        }
      }
    }
    return inUse
  }

  private func _findReservedTalkers(
    participant: Participant<MSRPApplication<P>>
  ) -> Set<MSRPTalkerAdvertiseValue> {
    // the talkers actually reserving bandwidth on this port are those whose applied per-port
    // reservation is Listener Ready/Ready Failed (a Forwarding dynamic reservation entry); a
    // stream filtered on this egress (no listener, Asking Failed, or admission/STP failure)
    // does not consume bandwidth (35.2.4.2, Table 35-13/35-14)
    guard let reservations = _reservations[participant.port.id] else { return [] }
    return Set(reservations.values.compactMap { reservation in
      guard reservation.declarationType == .listenerReady ||
        reservation.declarationType == .listenerReadyFailed,
        let talker = reservation.talker as? MSRPTalkerAdvertiseValue
      else { return nil }
      return talker
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

    var talkers = _findReservedTalkers(participant: participant)

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
      let ingress = try findParticipant(for: contextIdentifier, port: port)
      // 35.2.2.8: MSRP does not support changing a FirstValue field of a registered StreamID;
      // reject the change and keep the existing valid registration rather than silently dropping
      // it.
      // Scope to the same declaration type: an Advertise<->Failed transition is not a FirstValue
      // change and is handled by the mutual-exclusion deregistration below.
      if let existing = ingress.findAttribute(
        attributeType: attributeType.rawValue,
        matching: .matchAnyIndex(talkerValue.streamID.index)
      )?.1 as? any MSRPTalkerValue,
        MSRPTalkerFirstValue(existing) != MSRPTalkerFirstValue(talkerValue)
      {
        _logger
          .error(
            "MSRP: rejecting changed FirstValue for registered stream \(talkerValue.streamID) on \(port) (35.2.2.8)"
          )
        throw MRPError.doNotPropagateAttribute
      }
      // mutual exclusion: clear the opposite talker registration on the source port
      if eventSource == .peer {
        _deregisterOppositeTalkerRegistration(
          participant: ingress,
          declarationType: talkerValue.declarationType!,
          streamID: talkerValue.streamID
        )
      }
      _streamDidUpdate(talkerValue.streamID)
    case .listener:
      _streamDidUpdate((attributeValue as! MSRPListenerValue).streamID)
    case .domain:
      let domain = (attributeValue as! MSRPDomainValue)
      let isEndStation = await controller?.isEndStation ?? false
      try withPortState(port: port) { portState in
        if isEndStation {
          // 35.2.2.9.3/.4: an end station adopts its neighbour's SRclassPriority and SRclassVID,
          // joining the attached network's SR domain -- so it is not a domain boundary port
          // (unless PFC on the adopted priority forbids the credit-based shaper, 34.5).
          portState.srClassPriorityMap[domain.srClassID] = domain.srClassPriority
          portState.srpClassVID[domain.srClassID] = VLAN(vid: domain.srClassVID)
          portState.srpDomainBoundaryPort[domain.srClassID] =
            portState.pfcEnabledPriorities.contains(domain.srClassPriority)
        } else {
          // a bridge keeps its management-configured SRclassPriority: a neighbour declaring a
          // different priority (or PFC on the local priority) marks a domain boundary (35.2.1.4)
          let srClassPriority = portState.srClassPriorityMap[domain.srClassID]
          let isSrpDomainBoundaryPort = srClassPriority != domain.srClassPriority ||
            srClassPriority.map { portState.pfcEnabledPriorities.contains($0) } ?? false
          _logger
            .debug(
              "MSRP: port \(port) srClassID \(domain.srClassID) local srClassPriority \(String(describing: srClassPriority)) peer srClassPriority \(domain.srClassPriority): \(isSrpDomainBoundaryPort ? "is" : "not") a domain boundary port"
            )
          portState.srpDomainBoundaryPort[domain.srClassID] = isSrpDomainBoundaryPort
        }
      }
    }
    throw MRPError.doNotPropagateAttribute
  }

  func _streamDidUpdate(_ streamID: MSRPStreamID) {
    _pendingStreams.append(streamID)
    guard _streamUpdateTask == nil else { return }
    _streamUpdateTask = Task { [weak self] in await self?._applyPendingStreamUpdates() }
  }

  private func _applyPendingStreamUpdates() async {
    while !_pendingStreams.isEmpty {
      let streamID = _pendingStreams.removeFirst()
      let plan = _makeStreamPlan(streamID)
      do { try await _applyStreamPlan(plan) }
      catch { _logger.error("MSRP: recompute failed for stream \(streamID): \(error)") }
      // a stream that just reserved may have displaced lower-importance streams (Avnu §9.1);
      // queue them so they re-evaluate admission and declare Failed (drained in this loop)
      for displaced in plan.displacedStreams where displaced != streamID {
        _streamDidUpdate(displaced)
      }
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

      // the bound talker's own port faces the talker, not a listener: never propagate the
      // talker, merge a listener, or program admission back out the source port. On a
      // point-to-point source link don't reserve a path back out it either; otherwise a
      // listener registered on the (shared) source port still reserves locally
      if participant.port == boundTalker.0.port {
        // a listener on a shared (non-p2p) source link reserves locally; only Ready/Ready
        // Failed create a reservation (Table 35-13/35-14), and a failed talker reserves nothing
        if !participant.port.isPointToPoint, failed == nil,
           let listener = _findListenerRegistration(for: streamID, participant: participant),
           let ownDeclaration = MSRPDeclarationType(attributeSubtype: listener.1),
           ownDeclaration == .listenerReady || ownDeclaration == .listenerReadyFailed
        {
          plan.listenerPorts.append((participant, ownDeclaration))
        }
        return
      }

      // global talker failed fails everywhere, otherwise apply bandwidth
      // check on this listener port in case we should declare failed locally
      var egressFailure: MSRPFailure? = failed
        .map { MSRPFailure(systemID: $0.systemID, failureCode: $0.failureCode) }
      if egressFailure == nil {
        do {
          try _canBridgeTalker(participant: participant, talker: boundTalker.1)
        } catch let error as MSRPFailure {
          egressFailure = error
        } catch {}
      }

      if let listener = _findListenerRegistration(for: streamID, participant: participant),
         let ownDeclaration = MSRPDeclarationType(attributeSubtype: listener.1)
      {
        // only Ready/Ready Failed create a reservation (Table 35-13/35-14); an Asking Failed
        // listener (whether declared, or forced by a local admission failure) reserves nothing,
        // and any prior reservation on the port is torn down by the withdraw sweep in
        // _applyStreamPlan — so it does not enter listenerPorts and touches no hardware
        let declarationType = egressFailure != nil ? .listenerAskingFailed : ownDeclaration
        if declarationType == .listenerReady || declarationType == .listenerReadyFailed {
          plan.listenerPorts.append((participant, declarationType))
          // Avnu §9.1: this stream now reserves on the port, so collect the lower-importance
          // streams it displaces; their own recompute then declares them Failed
          if let portState = _portStates[participant.port.id] {
            plan.displacedStreams.formUnion(_displacedStreamIDs(
              participant: participant, portState: portState, talker: boundTalker.1
            ))
          }
        }

        // merge registered listeners toward the talker. The merge uses the listener as
        // registered: per Table 35-12 (35.2.4.4.1) the propagation keys on the Talker
        // *registered* on the source port (the bound talker), not on a local per-egress
        // admission result — that case is handled by the post-loop override below.
        plan.mergedListener = _mergeListener(
          declarationType: ownDeclaration,
          with: plan.mergedListener
        )
      }

      // never declare the talker onto a port that already registered it
      guard _findTalkerRegistration(for: streamID, participant: participant) == nil else { return }

      plan.talkerDeclarations.append((participant, egressFailure))
    }

    // Table 35-12 (35.2.4.4.1): if the bound Talker is *registered* as Failed, any associated
    // Listener Ready/ReadyFailed must be propagated toward the talker as Asking Failed.
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

    // admit the stream on the Talker's ingress port for a "secure" switch (no-op unless
    // .configureIngressMdb); kept until the Talker leaves, so Listener churn does not touch it
    try? await _updateIngressFdbEntry(streamID: streamID, boundTalker: boundTalker)

    var declaredTalkerPorts = Set<P.ID>()

    // re-sample per-hop latency this recompute so a since-changed gPTP meanLinkDelay is reflected;
    // only the cache (not the per-stream guarantee) resets, and the loop below re-fills it so every
    // talker on a port still reports a uniform value within this pass (35.2.2.8.6)
    for (participant, _) in plan.talkerDeclarations {
      _portStates[participant.port.id]?.portTcMaxLatency = nil
    }

    for (participant, failure) in plan.talkerDeclarations {
      // a newer event re-marked this stream while we awaited: abandon the now-stale plan
      // rather than emitting declarations from it; the pending recompute will reapply (10.3)
      if _pendingStreams.contains(streamID) { return }
      if await _shouldPruneTalkerDeclaration(port: participant.port, talker: boundTalker.1) {
        continue // pruned: the sweep below withdraws any existing declaration
      }

      // per-hop latency (35.2.2.8.6) terms b/c/d (frame time + gPTP meanLinkDelay) cached per port,
      // so every stream adds the identical increment. When gPTP has no meanLinkDelay yet the value
      // is provisional: an over-estimate (802.1AS neighborPropDelayThresh, 800 ns -- an asCapable
      // link's delay cannot exceed it), so a downstream bridge that baselines our warm-up
      // advertisement only ever sees the converged latency *decrease* (code 7 trips on increases).
      // It is neither cached nor used to set our own guarantee below.
      let priority = boundTalker.1.priorityAndRank.dataFramePriority
      var latency = boundTalker.1.accumulatedLatency
      let tcLatency: Int
      let latencyIsProvisional: Bool
      if let cached = _portStates[participant.port.id]?.portTcMaxLatency {
        tcLatency = cached
        latencyIsProvisional = false
      } else {
        var sampled: Int?
        do {
          sampled = try await participant.port.getPortTcMaxLatency(for: priority)
        } catch MRPError.ptpNotReady {
          // expected while gPTP converges; fall through to the provisional over-estimate
        } catch {
          // a real failure (gPTP daemon unreachable, netlink error) must be visible, not
          // silently indistinguishable from warm-up
          _logger.error("MSRP: failed to sample per-hop latency on \(participant.port): \(error)")
        }
        if let sampled {
          _portStates[participant.port.id]?.portTcMaxLatency = sampled
          tcLatency = sampled
          latencyIsProvisional = false
        } else {
          tcLatency = srpPortTcMaxLatency(
            meanLinkDelayNs: 800, linkSpeedKbps: participant.port.linkSpeed
          )
          latencyIsProvisional = true
        }
      }
      // term a): the SR-class worst-case queuing delay -- a CBS frame can wait up to one class
      // measurement interval per hop (125 us class A / 250 us class B), the only class-dependent
      // term.
      var cmiLatency = 0
      if let srClassID = _portStates[participant.port.id]?
        .reverseMapSrClassPriority(priority: priority),
        let cmi = try? srClassID.classMeasurementInterval
      {
        cmiLatency = cmi * 1000 // class measurement interval is in microseconds
      }
      // saturate: accumulatedLatency is peer-supplied, so a value near UInt32.max plus this hop's
      // latency would otherwise overflow the UInt32 sum and trap (a remotely triggerable DoS).
      let (sum, overflow) = latency
        .addingReportingOverflow(UInt32(clamping: tcLatency + cmiLatency))
      latency = overflow ? .max : sum

      // re-check after the awaits above: a concurrent withdraw may have re-queued the stream, in
      // which case emitting from this stale plan would advertise a since-withdrawn declaration
      if _pendingStreams.contains(streamID) { return }

      // 35.2.2.8.6: the reported latency must not increase during the reservation's life. Compare
      // against the value first declared (the initial guarantee); an increase fails the stream
      // with reportedLatencyHasChanged (code 7). The first successful declaration sets the
      // guarantee.
      var failure = failure
      if failure == nil, !latencyIsProvisional {
        if let baseline = _portStates[participant.port.id]?.configuredLatency[streamID] {
          if latency > baseline {
            failure = MSRPFailure(systemID: _systemID, failureCode: .reportedLatencyHasChanged)
          }
        } else {
          _portStates[participant.port.id]?.configuredLatency[streamID] = latency
        }
      }

      // 35.2.6: a type change (e.g. Advertise->Failed) behaves as if the old declaration was
      // withdrawn before the new one, so leave the opposite declared Talker type first.
      let declarationType: MSRPDeclarationType = failure == nil ? .talkerAdvertise : .talkerFailed
      if let oppositeType = declarationType.attributeType.oppositeAttributeType {
        _leaveDeclaredAttributes(participant, streamID: streamID, types: [oppositeType])
      }

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
      // the reservation ended on this port: drop its latency guarantee (35.2.2.8.6)
      _portStates[participant.port.id]?.configuredLatency[streamID] = nil
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
      // a newer event re-marked this stream: abandon the stale plan; it will be recomputed
      if _pendingStreams.contains(streamID) { return }

      let desired = Reservation(declarationType: declarationType, talker: boundTalker.1)

      // idempotency: only touch the kernel when the reservation actually changed
      if _reservations[participant.port.id]?[streamID] != desired {
        do {
          try await _updatePortParameters(
            port: participant.port, streamID: streamID,
            mergedDeclarationType: declarationType, talkerRegistration: boundTalker
          )
        } catch {
          // don't abort the whole plan (nor record the reservation) on one port's failure:
          // the other ports and the withdraw sweep still run, and the unrecorded reservation is
          // retried on the next recompute via the idempotency check above
          _logger.error(
            "MSRP: failed to program reservation for stream \(streamID) on port \(participant.port): \(error)"
          )
          continue
        }
      }
      _reservations[participant.port.id, default: [:]][streamID] = desired
    }

    for (portID, talker) in _reservationsToWithdraw(streamID, keeping: keep) {
      if _pendingStreams.contains(streamID) { return }

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
    // the Talker is gone: drop the secure-switch ingress admission entry (no-op if none)
    await _removeIngressFdbEntry(streamID: streamID)

    for (portID, talker) in _reservationsToWithdraw(streamID, keeping: []) {
      if let participant = _participant(for: portID) {
        try? await _updatePortParameters(
          port: participant.port, streamID: streamID,
          mergedDeclarationType: nil, talkerRegistration: (participant, talker)
        )
      }
      _clearReservation(portID: portID, streamID: streamID)
    }

    // Leaving the .listener declaration here is the Avnu ProAV Bridge §9.1 proxy: when the Talker
    // departs while a Listener is still registered, the bridge generates the Listener Leave back
    // toward the Talker on the Listener's behalf, rather than waiting for the downstream Listener
    // to react to the Talker withdrawal.
    apply(for: MAPBaseSpanningTreeContext) { participant in
      _portStates[participant.port.id]?.configuredLatency[streamID] = nil
      _leaveDeclaredAttributes(
        participant, streamID: streamID, types: [.talkerAdvertise, .talkerFailed, .listener]
      )
    }
  }

  // leave our own declared attributes (of the given types) for a stream on one port.
  // Any declared attribute is left, including one that is also registered: leaving with
  // eventSource .map withdraws our Applicant declaration without clearing the Registrar,
  // which is what stops us declaring toward a port that now registers the stream itself.
  @discardableResult
  private func _leaveDeclaredAttributes(
    _ participant: Participant<MSRPApplication>, streamID: MSRPStreamID,
    types: [MSRPAttributeType], eventSource: EventSource = .map
  ) -> Bool {
    // true if any declaration existed (not necessarily that the leave succeeded): callers use
    // this to decide whether a subsequent join replaces a prior declaration (isNew: false).
    var hadDeclaration = false
    for type in types {
      for attr in participant.findAllAttributesUnchecked(
        attributeType: type.rawValue, matching: .matchAnyIndex(streamID.id), isolation: self
      ) where attr.isDeclared {
        hadDeclaration = true
        try? participant.leave(
          attributeType: type.rawValue, attributeSubtype: attr.attributeSubtype,
          attributeValue: attr.attributeValue, eventSource: eventSource
        )
      }
    }
    return hadDeclaration
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
        // 35.2.1.4(h): with the peer's Domain registration withdrawn, the port declares a Domain
        // for the class but no longer has a registration for it, so it is again a boundary port
        // (not "unknown"/core -- a nil here reads as non-boundary in _canBridgeTalker).
        portState.srpDomainBoundaryPort[domain.srClassID] = true
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
    // event can fire many context updates and the Domain is declared New (not
    // Applicant-suppressed).
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
