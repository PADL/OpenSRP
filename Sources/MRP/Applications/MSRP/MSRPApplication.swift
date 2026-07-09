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
    Self([.leaveImmediate, .disableFlowControl])
}

// Per-port admission control: restrict the AVB traffic classes to reserved
// streams. Mechanism is platform-specific; the bridge dispatches on the type.
public enum MSRPFilteringType: String, Sendable, CaseIterable {
  case marvell
  case tcflower
}

protocol MSRPAwareBridge<P>: Bridge where P: AVBPort {
  // Set per-port admission control via the given mechanism; requireIngressFdbEntry
  // picks the mode that checks the ingress reservation entry, `filter` is the set
  // of SR classes whose un-reserved frames to drop (§6, once in the domain).
  func configureFiltering(
    on port: P, type: MSRPFilteringType, requireIngressFdbEntry: Bool, filter: Set<SRclassID>
  ) async throws
  func unconfigureFiltering(on port: P, type: MSRPFilteringType) async throws

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

// a programmed per-port reservation: the merged declaration type plus the bound Talker value. Held
// per port in MSRPPortState.reservations, dropped with the port state on removal. Equality ignores
// the Talker's non-reserving fields (latency, failure) so an idempotency check only reprograms the
// kernel when the reservation itself changed.
private struct Reservation: Equatable, Sendable {
  let declarationType: MSRPDeclarationType?
  let talker: any MSRPTalkerValue

  var isListenerReady: Bool { declarationType?.isListenerReady == true }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.declarationType == rhs.declarationType &&
      lhs.talker.dataFrameParameters == rhs.talker.dataFrameParameters &&
      lhs.talker.tSpec == rhs.talker.tSpec &&
      lhs.talker.priorityAndRank == rhs.talker.priorityAndRank
  }
}

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
  // last-known gPTP asCapable (802.1AS) per port, refreshed on each indication; nil until first
  // read. A definitive not-asCapable is an SR domain boundary (35.2.1); an unreadable PMC is
  // unknown, not false, and does not block -- mirroring the provisional latency path.
  var asCapable: Bool?
  // per-stream reported-latency guarantee first declared on this port (35.2.2.8.6); lives here so
  // it is dropped with the port state on removal.
  var configuredLatency = [MSRPStreamID: UInt32]()
  // programmed reservations on this port keyed by stream: the merged declaration type + bound
  // Talker last applied to the kernel, for idempotent (re)programming and the withdraw sweep.
  fileprivate var reservations = [MSRPStreamID: Reservation]()

  // drop the cached per-hop latency and asCapable on a link change (flap/STP) so the next recompute
  // re-samples gPTP. Per-stream guarantees survive for the reservation's life (35.2.2.8.6):
  // a topology-driven latency increase must trip code 7, not silently re-baseline.
  mutating func invalidate() {
    portTcMaxLatency = nil
    asCapable = nil
  }

  func reverseMapSrClassPriority(priority: SRclassPriority) -> SRclassID? {
    srClassPriorityMap.first(where: { $0.value == priority })?.key
  }

  // Effective SRP domain boundary: our own live status (non-AVB medium / PFC priority / not-
  // asCapable -- none cached) OR the peer's cached Domain relationship. nil = none determined;
  // admission treats nil as non-boundary (!= true), REST reports a boundary (?? true).
  func isSrpDomainBoundary(
    for srClassID: SRclassID,
    application: MSRPApplication<P>
  ) -> Bool? {
    // our own status (802.1BA §6.4 / 34.5 / 35.2.1), derived live so a link change can't stale it
    if !msrpPortEnabledStatus { return true }
    if let priority = srClassPriorityMap[srClassID], pfcEnabledPriorities.contains(priority) {
      return true
    }
    if !application._ignoreAsCapable, asCapable == false { return true }
    // the peer's Domain relationship only (35.2.1.4 h① no registration / h② priority differs)
    return srpDomainBoundaryPort[srClassID]
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
    stpPortState = port.stpPortState ?? .forwarding
    srpDomainBoundaryPort = .init(uniqueKeysWithValues: application._allSRClassIDs.map { (
      $0,
      false // peer-derived only; our own status is live in isSrpDomainBoundary
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
  let _filtering: MSRPFilteringType?

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
    // ingress ports of the listeners merged into mergedListener; a received New (or a topology
    // change) on any of them marks the propagated Listener New (10.3 a)
    var listenerSourcePorts = Set<P.ID>()
    var listenerPorts =
      [(participant: Participant<MSRPApplication>, declarationType: MSRPDeclarationType)]()
    // lower-importance streams this one displaces by reserving (Avnu §9.1); re-evaluated by
    // their own recompute, where they find themselves over-budget and declare Failed
    var displacedStreams = Set<MSRPStreamID>()
  }

  // Ports carrying a stream's group (DA, VLAN) MDB entry: egress Listener-Ready ports plus (secure
  // switch) the Talker's ingress admission port. One reconciler owns this set; params relocate the
  // group when the Talker changes frame parameters. See _updateGroupReservations.
  private struct GroupReservation {
    let params: MSRPDataFrameParameters
    var ports: Set<P.ID>
  }

  private var _pendingStreams = OrderedSet<MSRPStreamID>()
  private var _streamUpdateTask: Task<(), Never>?
  // 35.2.2.8: streams whose registered FirstValue a peer tried to change; each stays Talker Failed
  // (code 16) until its talker withdraws (cleared in _withdrawStream). Keyed per ingress port so a
  // clean declaration of the same StreamID on another port cannot clear a genuine conflict.
  private var _firstValueViolations = [MSRPStreamID: Set<P.ID>]()
  // 10.3 a): propagate a declaration as New when it was received New (or its ingress port had a
  // topology change). Per stream, the ingress ports pending New propagation; consumed once the
  // recompute emits the propagated declaration, so a later refresh is a plain Join (one-shot).
  private var _receivedNew = [MSRPStreamID: Set<P.ID>]()
  // ports whose spanning-tree state just changed: a declaration propagated from such a port is
  // forced New (10.3 a). Approximates tcDetected (13.25); cleared once the recompute drains.
  private var _tcDetected = Set<P.ID>()
  private var _reservedGroupPorts: [MSRPStreamID: GroupReservation] = [:]
  // ports whose per-port SR admission filter (§6) state is currently applied; the
  // last SR-class set written, so a recompute re-writes only on a change.
  private var _portFilterApplied = [P.ID: Set<SRclassID>]()

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

  fileprivate nonisolated var _configureFiltering: Bool { _filtering != nil }

  nonisolated var _ignoreAsCapable: Bool { _flags.contains(.ignoreAsCapable) }
  public nonisolated var registrarLeaveImmediate: Bool { _flags.contains(.leaveImmediate) }

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
    maxTalkerAttributes: Int = 150,
    filtering: MSRPFilteringType? = nil
  ) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    _flags = flags
    _filtering = filtering
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

  // Configure an AVB-capable port's queues and return the SR-class priority map to record for it
  // (nil when the port is neither AVB capable nor forced, so the caller skips it). When we own the
  // queues we program the mqprio with the default map and return that; otherwise we read it back.
  // Shared by didAdd and onContextUpdated so a port that goes AVB capable after startup is set up
  // the same way, rather than left with an empty map that fails every talker.
  private func _configureAvbCapablePort(
    _ port: P,
    bridge: any MSRPAwareBridge<P>
  ) async throws -> SRClassPriorityMap? {
    guard port.isAvbCapable || _forceAvbCapable else { return nil }
    // Per-port admission control before queues so it is up first; the in-domain
    // filter is added later once the port is in the domain (§6).
    await _applyPortFiltering(port: port, bridge: bridge)
    if _configureEgressQueues || _configureIngressQueues {
      if _configureEgressQueues {
        // best-effort unconfigure (a fresh port has no mqprio to remove); it must not abort the
        // configure that follows, or the port is left with no mqprio and every CBS program ENOENTs
        try? await bridge.unconfigureEgressQueues(port: port)
        // a failure throws: didAdd surfaces it to its caller, onContextUpdated logs it and leaves
        // the port map-less so its isEmpty guard retries on a later update
        try await bridge.configureEgressQueues(
          port: port,
          srClassPriorityMap: DefaultSRClassPriorityMap,
          queues: _queues,
          forceAvbCapable: _forceAvbCapable
        )
      }
      if _configureIngressQueues {
        // configureIngressQueues is ref-counted at the bridge and handles both per-port ingress
        // maps (e.g. 88E6390) and global maps shared across all ports (e.g. 88E6352). No pre-clear
        // is needed here (a blind per-port delete would tear down a shared global map for the other
        // member ports). Ingress (DCBNL) configuration is best-effort: kernels/switches without the
        // DCBNL priority-map migration return EOPNOTSUPP; log and continue.
        do {
          try await bridge.configureIngressQueues(
            port: port,
            srClassPriorityMap: DefaultSRClassPriorityMap,
            queues: _queues,
            forceAvbCapable: _forceAvbCapable
          )
        } catch {
          _logger.error("MSRP: failed to configure ingress queues for port \(port): \(error)")
        }
      }
      return DefaultSRClassPriorityMap
    } else if port.isAvbCapable {
      return await (try? bridge.getSRClassPriorityMap(port: port)) ?? SRClassPriorityMap()
    } else {
      _logger.warning("MSRP: forcing port \(port) to advertise as AVB capable")
      return DefaultSRClassPriorityMap
    }
  }

  // §6 / Table 6-5: the SR classes for which this port is in the SR domain --
  // non-boundary with a matching peer Domain registered -- so a bridge may drop
  // their un-reserved frames. A boundary class is excluded (it regenerates).
  private func _portInDomainSRClasses(port: P) -> Set<SRclassID> {
    guard let participant = try? findParticipant(for: MAPBaseSpanningTreeContext, port: port),
          let portState = try? withPortState(port: port, { $0 }) else { return [] }
    var result = Set<SRclassID>()
    for srClassID in _allSRClassIDs {
      guard portState.isSrpDomainBoundary(for: srClassID, application: self) == false,
            let local = portState.srClassPriorityMap[srClassID] else { continue }
      // require a positively registered matching peer Domain (guards the optimistic
      // srpDomainBoundaryPort default of false before any recompute has run)
      for (_, value) in participant.findAttributes(
        attributeType: MSRPAttributeType.domain.rawValue, matching: .matchAny
      ) {
        if let d = value as? MSRPDomainValue, d.srClassID == srClassID, d.srClassPriority == local {
          result.insert(srClassID)
          break
        }
      }
    }
    return result
  }

  // Apply (or re-apply) a port's admission control and the §6 in-domain filter,
  // only when the filter state changed, so a recompute is a no-op on no change.
  private func _applyPortFiltering(port: P, bridge: any MSRPAwareBridge<P>) async {
    guard let _filtering else { return }
    let filter = _portInDomainSRClasses(port: port)
    guard _portFilterApplied[port.id] != filter else { return }
    do {
      try await bridge.configureFiltering(
        on: port, type: _filtering, requireIngressFdbEntry: _configureIngressMdb, filter: filter
      )
      _portFilterApplied[port.id] = filter
    } catch {
      _logger.error("MSRP: failed to set admission control on port \(port): \(error)")
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

      guard let map = try await _configureAvbCapablePort(port, bridge: bridge) else {
        _logger.debug("MSRP: port \(port) is not AVB capable, skipping")
        continue
      }
      srClassPriorityMap[port.id] = map
      _logger.debug("MSRP: allocating port state for \(port), prio map \(map)")
      // best-effort; folded into the boundary-port state below (fetched here, in the awaiting
      // loop, so the state-building loop stays synchronous)
      pfcEnabledPriorities[port.id] = await (try? port.pfcEnabledPriorities) ?? []
    }

    for port in context {
      var portState = try MSRPPortState(application: self, port: port)
      if let srClassPriorityMap = srClassPriorityMap[port.id] {
        portState.srClassPriorityMap = srClassPriorityMap
      }
      // 34.5: an SR class whose priority has PFC enabled is a boundary port; that check is live in
      // isSrpDomainBoundary, so here we only need to hold the priority set
      if let pfc = pfcEnabledPriorities[port.id] {
        portState.pfcEnabledPriorities = pfc
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

    // A port that goes AVB capable after startup (its link was down when didAdd ran) was skipped by
    // didAdd and still has an empty map. Configure it now as didAdd would: when we own the queues
    // this writes its mqprio with the default map (no TC notification fires on link-up), so it can
    // declare SR domains instead of failing every talker with
    // requestedPriorityIsNotAnSRClassPriority
    // until restart. When we do not own the queues we can only read the map back. Do this BEFORE
    // the
    // stream recompute below, so a reservation programmed on a freshly-capable port finds its
    // mqprio.
    if let bridge = (controller?.bridge as? any MSRPAwareBridge<P>) {
      _bridgeSystemID = await bridge.systemID
      var configuredMaps = [P.ID: SRClassPriorityMap]()
      for port in context where port.isAvbCapable || _forceAvbCapable {
        guard let index = _portStates.index(forKey: port.id),
              _portStates.values[index].srClassPriorityMap.isEmpty else { continue }
        do {
          guard let map = try await _configureAvbCapablePort(port, bridge: bridge),
                !map.isEmpty else { continue }
          configuredMaps[port.id] = map
        } catch {
          // keep the port map-less (retried on a later update) without aborting the other ports
          _logger.error("MSRP: failed to configure late-AVB-capable port \(port): \(error)")
        }
      }
      for (portID, map) in configuredMaps {
        guard let index = _portStates.index(forKey: portID) else { continue }
        _portStates.values[index].srClassPriorityMap = map
      }
    }

    // refresh spanning-tree state from the fresh port (a synchronous read, no actor hop); a change
    // is a topology change, so invalidate the port's latency state here (the single place STP
    // clears it) and re-derive the active streams
    var stpChanged = false
    for port in context {
      guard let index = _portStates.index(forKey: port.id) else { continue }
      // nil = an AF_UNSPEC snapshot with no bridge-port state; keep the last-known STP state
      guard let stpPortState = port.stpPortState else { continue }
      if _portStates.values[index].stpPortState != stpPortState {
        _logger.info("MSRP: port \(port) spanning-tree state now \(stpPortState)")
        _portStates.values[index].stpPortState = stpPortState
        _portStates.values[index].invalidate()
        _tcDetected.insert(port.id) // 10.3 a): declarations propagated from this port are New
        stpChanged = true
      }
    }
    if stpChanged {
      // a topology change can move a port's worst-case path latency (35.2.2.8.6): the recompute
      // below re-samples per-hop latency fresh and fails a stream whose reported latency rose above
      // its guarantee.
      _forceUpdateActiveStreams()
      // no drain in flight means nothing was queued to consume the New marking: clear it now so
      // it cannot linger and spuriously mark an unrelated declaration New long after the TC
      if _streamUpdateTask == nil { _tcDetected.removeAll() }
    }

    for port in context {
      _logger.debug("MSRP: re-declaring domains for port \(port)")
      try _declareDomains(port: port)
    }
  }

  // re-derive every stream with a registered talker or a programmed reservation; used when a
  // port's Forwarding state changes (the active topology, and thus propagation, has changed)
  private func _forceUpdateActiveStreams() {
    var streamIDs = Set(_portStates.values.flatMap(\.reservations.keys))
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

    if _configureEgressQueues || _configureIngressQueues || _configureFiltering,
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
        // Reset the port's admission control, after the queues are gone.
        if let _filtering {
          do {
            try await bridge.unconfigureFiltering(on: port, type: _filtering)
          } catch {
            _logger.error("MSRP: failed to reset admission control on port \(port): \(error)")
          }
        }
      }
    }

    let vanishedPortIDs = Set(context.map(\.id))
    for port in context {
      _logger.debug("MSRP: port \(port) disappeared, removing")
      // this also drops the port's cached reservations so a later re-add reprograms the hardware
      _portStates.removeValue(forKey: port.id)
      // forget the applied filter state so a re-added port is reprogrammed
      _portFilterApplied.removeValue(forKey: port.id)
    }
    // a violation (code 16) whose talker registration vanishes with its port sees no withdraw or
    // revert to clear it: drop the vanished ports so a clean future re-declaration is not failed
    for streamID in Array(_firstValueViolations.keys) {
      _firstValueViolations[streamID]?.subtract(vanishedPortIDs)
      if _firstValueViolations[streamID]?.isEmpty ?? true { _firstValueViolations[streamID] = nil }
    }
    // the kernel drops MDB entries on a vanished port; forget any group membership we tracked on
    // one so the cache does not go stale (a stale port would suppress a later re-add)
    if !vanishedPortIDs.isEmpty {
      for streamID in Array(_reservedGroupPorts.keys) {
        guard var entry = _reservedGroupPorts[streamID] else { continue }
        entry.ports.subtract(vanishedPortIDs)
        _reservedGroupPorts[streamID] = entry.ports.isEmpty ? nil : entry
      }
    }
  }

  // Withdraw the dynamic-reservation MDB entries we programmed (egress Listener reservations and
  // secure-admission ingress entries) so the switch stops forwarding reserved streams once no
  // participant manages them. In-memory state is discarded after, so the caches are not cleared.
  public func shutdown() async {
    for streamID in Array(_reservedGroupPorts.keys) {
      await _updateGroupReservations(streamID: streamID, params: nil, desired: [:])
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
    switch MSRPAttributeType(rawValue: attributeType) {
    case .talkerAdvertise, .talkerFailed:
      guard let talker = attributeValue as? any MSRPTalkerValue else { return true }
      // 35.1.3.1: the stream's SR-class VLAN must be present on the port.
      guard port.vlans.contains(talker.dataFrameParameters.vlanIdentifier) else { return false }
      // Avnu ProAV §9.3: hold the Registrar MT once the global Talker limit is reached, so the
      // additional stream is ignored (never registered). Same actor as the Participant.
      return assumeIsolated { $0._isTalkerRegistrationPermitted(streamID: talker.streamID) }
    default:
      return true
    }
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

  public func periodic(for _: MAPContextIdentifier? = nil) async throws {
    // MSRP does no PeriodicTransmission (Avnu §9.1); the tick resamples gPTP asCapable, which
    // changes
    // with no MRP event -- keeping the cache the recompute and REST view read fresh. On any change,
    // re-plan every talker: a boundary shift can affect any stream's admission (35.2.1).
    var changed = false
    for participant in findParticipants(for: MAPBaseSpanningTreeContext) {
      if await _updateAsCapable(port: participant.port) { changed = true }
    }
    guard changed, !_ignoreAsCapable else { return }
    apply(for: MAPBaseSpanningTreeContext) { participant in
      for type in [MSRPAttributeType.talkerAdvertise, .talkerFailed] {
        for attribute in participant.findAllAttributesUnchecked(
          attributeType: type.rawValue, matching: .matchAny, isolation: self
        ) where attribute.isRegistered {
          if let talker = attribute.attributeValue as? any MSRPTalkerValue {
            _streamDidUpdate(talker.streamID)
          }
        }
      }
    }
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
           matching: .matchIndex(
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

  // Refresh the boundary decision's input (consumed by the sync recompute in _makeStreamPlan, which
  // cannot query PTP) and the REST view. Sampled per indication and on the 1 s periodic() tick,
  // since
  // a gPTP asCapable change carries no link event to invalidate a cache. Returns whether it
  // changed;
  // an unreadable PMC is unknown, not false, so keep the last-known value (35.2.1).
  @discardableResult
  private func _updateAsCapable(port: P) async -> Bool {
    // Not-enabled (link down / not AVB-capable): no gPTP peer. Leave asCapable unsampled (nil, set
    // by invalidate on the link change) not a stale PMC read; REST/admission treat nil as false.
    guard _portStates[port.id]?.msrpPortEnabledStatus == true else { return false }
    do {
      let asCapable = try await port.isAsCapable
      // never hold a _portStates index across the await above: it suspends the
      // actor, and a concurrent add/remove would invalidate the index.
      return (try? withPortState(port: port) { portState in
        let changed = portState.asCapable != asCapable
        portState.asCapable = asCapable
        return changed
      }) ?? false
    } catch {
      _logger.trace("MSRP: keeping last-known asCapable for \(port): \(error)")
      return false
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
      ), !existingTalkerRegistration.isEqualIdentity(to: talker) {
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

      // 35.2.4.3: a Talker Advertise propagating out an SR domain boundary port -- domain/PFC or a
      // not-asCapable egress port (35.2.1) -- is converted to Talker Failed code 8. nil (SRP
      // determined none) propagates, matching the prior nil-is-non-boundary admission rule.
      guard portState.isSrpDomainBoundary(for: srClassID, application: self) != true else {
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

  // Render port IDs with their interface names for logging, e.g. "[lan3(9), lan1(7)]".
  private func _renderPorts(_ ids: some Sequence<P.ID>) -> String {
    "[" + ids.map { id in _participant(for: id).map { "\($0.port)(\(id))" } ?? "\(id)" }
      .joined(separator: ", ") + "]"
  }

  // Converge a stream's group MDB entry to `desired` (portID -> Port) in one pass, diffing against
  // the tracked set. params == nil tears the whole group down (Talker withdrawn/shutdown).
  private func _updateGroupReservations(
    streamID: MSRPStreamID,
    params: MSRPDataFrameParameters?,
    desired: [P.ID: P]
  ) async {
    guard let controller, let bridge = controller.bridge as? any MMRPAwareBridge<P> else { return }

    // a Talker that changed its frame parameters (or withdrew) orphans the group under the old
    // (DA, VLAN) key: tear that down in full before programming the current one
    if let stale = _reservedGroupPorts[streamID], stale.params != params {
      await bridge.deregister(
        macAddress: stale.params.destinationAddress, vlan: stale.params.vlanIdentifier,
        from: Set(stale.ports.compactMap { _participant(for: $0)?.port })
      )
      _reservedGroupPorts[streamID] = nil
    }

    guard let params else {
      _reservedGroupPorts[streamID] = nil
      return
    }

    let current = _reservedGroupPorts[streamID]?.ports ?? []
    let desiredIDs = Set(desired.keys)
    var programmed = current.intersection(desiredIDs)

    let addIDs = desiredIDs.subtracting(current)
    if !addIDs.isEmpty {
      _logger.debug(
        "MSRP: registering group MDB entry for \(_macAddressToString(params.destinationAddress)) vlan \(params.vlanIdentifier.vid) on ports \(_renderPorts(addIDs))"
      )
      // track exactly the ports the bridge programmed: a per-port failure leaves that port
      // untracked so the next recompute retries it, instead of leaking it on a later teardown
      await programmed.formUnion(bridge.register(
        macAddress: params.destinationAddress, vlan: params.vlanIdentifier,
        flags: .dynamicReservation, on: Set(addIDs.compactMap { desired[$0] })
      ))
    }

    let removeIDs = current.subtracting(desiredIDs)
    if !removeIDs.isEmpty {
      _logger.debug(
        "MSRP: deregistering group MDB entry for \(_macAddressToString(params.destinationAddress)) vlan \(params.vlanIdentifier.vid) on ports \(_renderPorts(removeIDs))"
      )
      await bridge.deregister(
        macAddress: params.destinationAddress, vlan: params.vlanIdentifier,
        from: Set(removeIDs.compactMap { _participant(for: $0)?.port })
      )
    }

    // a port removed during the register/deregister awaits was pruned from the cache by
    // onContextRemoved; don't resurrect it from the pre-await snapshot (its MDB entry is gone)
    programmed.formIntersection(_portStates.keys)
    _reservedGroupPorts[streamID] = programmed.isEmpty ? nil : GroupReservation(
      params: params, ports: programmed
    )
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
    guard let reservations = _portStates[participant.port.id]?.reservations else { return [] }
    return Set(reservations.values.compactMap { reservation in
      guard reservation.isListenerReady,
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
       declarationType?.isListenerReady == true
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
      if mergedDeclarationType?.isListenerReady == true {
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
      // MDB entries are owned by _updateGroupReservations; here we only track the port's CBS
      try await _updateOperIdleSlope(
        port: port,
        portState: portState,
        streamID: streamID,
        declarationType: mergedDeclarationType,
        talkerRegistration: talkerRegistration.1
      )
    } catch {
      _logger
        .error(
          "MSRP: failed to update port parameters for stream \(streamID): \(error)\(_forceAvbCapable ? ", ignoring" : "")"
        )
      guard _forceAvbCapable else { throw error }
    }
  }

  // 35.2.1.4 h): a boundary if the class is declared with no peer Domain registration (h.1) or any
  // carries a different priority (h.2). Own live status (non-AVB/PFC/asCapable) applied elsewhere.
  private func _recomputeSrpDomainBoundary(
    participant: Participant<MSRPApplication>, port: P, srClassID: SRclassID
  ) throws {
    try withPortState(port: port) { portState in
      guard let localPriority = portState.srClassPriorityMap[srClassID] else {
        // the port does not support this class (35.2.1.4 h.3): treat it as a boundary
        portState.srpDomainBoundaryPort[srClassID] = true
        return
      }
      var priorities = Set<SRclassPriority>()
      for (_, value) in participant.findAttributes(
        attributeType: MSRPAttributeType.domain.rawValue, matching: .matchAny
      ) {
        if let d = value as? MSRPDomainValue, d.srClassID == srClassID {
          priorities.insert(d.srClassPriority)
        }
      }
      portState.srpDomainBoundaryPort[srClassID] =
        priorities.isEmpty || priorities.contains { $0 != localPriority }
    }
  }

  // 35.2.2.8: true when any registered Talker declaration for the stream (either type) differs from
  // `value` in an immutable FirstValue field -- a same-type change or an Advertise<->Failed flip.
  private func _talkerFirstValueConflicts(
    on participant: Participant<MSRPApplication>, with value: any MSRPTalkerValue
  ) -> Bool {
    for type in [MSRPAttributeType.talkerAdvertise, .talkerFailed] {
      for (_, registered) in participant.findAttributes(
        attributeType: type.rawValue, matching: .matchAnyIndex(value.streamID.index)
      ) {
        if let registered = registered as? any MSRPTalkerValue,
           !registered.isEqualIdentity(to: value) { return true }
      }
    }
    return false
  }

  // a peer changing its Domain re-declares the new value without a Leave (35.2.4), so the old
  // registration lingers until ageout; drop it so a superseded priority can't hold a boundary (h).
  private func _supersedeStaleDomains(
    on participant: Participant<MSRPApplication>, keeping domain: MSRPDomainValue
  ) {
    for (_, value) in participant.findAttributes(
      attributeType: MSRPAttributeType.domain.rawValue, matching: .matchAnyIndex(domain.index)
    ) {
      guard let stale = value as? MSRPDomainValue, stale != domain else { continue }
      try? participant.deregister(
        attributeType: MSRPAttributeType.domain.rawValue, attributeValue: stale, eventSource: .peer
      )
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

    await _updateAsCapable(port: port)

    switch attributeType {
    case .talkerAdvertise, .talkerFailed:
      let talkerValue = (attributeValue as! any MSRPTalkerValue)
      let ingress = try findParticipant(for: contextIdentifier, port: port)
      // 35.2.2.8: a changed immutable FirstValue is forbidden -- reject the newcomer, keep the
      // original registration, and fail the stream (code 16) until the talker withdraws it.
      if _talkerFirstValueConflicts(on: ingress, with: talkerValue) {
        _logger
          .error(
            "MSRP: stream \(talkerValue.streamID) FirstValue conflict on \(port); failing (35.2.2.8)"
          )
        _firstValueViolations[talkerValue.streamID, default: []].insert(ingress.port.id)
        try? ingress.deregister(
          attributeType: attributeType.rawValue, attributeValue: talkerValue, eventSource: .peer
        )
      } else {
        _firstValueViolations[talkerValue.streamID]?.remove(ingress.port.id)
        if eventSource == .peer {
          // mutual exclusion: a clean Advertise<->Failed transition drops the opposite type
          // (35.2.6)
          _deregisterOppositeTalkerRegistration(
            participant: ingress,
            declarationType: talkerValue.declarationType!,
            streamID: talkerValue.streamID
          )
        }
      }
      // 10.3 a): remember a received New so the recompute propagates it as New (not JoinMt)
      if isNew { _receivedNew[talkerValue.streamID, default: []].insert(port.id) }
      _streamDidUpdate(talkerValue.streamID)
    case .listener:
      let listenerStreamID = (attributeValue as! MSRPListenerValue).streamID
      if isNew { _receivedNew[listenerStreamID, default: []].insert(port.id) }
      _streamDidUpdate(listenerStreamID)
    case .domain:
      let domain = (attributeValue as! MSRPDomainValue)
      let isEndStation = await controller?.isEndStation ?? false
      if isEndStation {
        try withPortState(port: port) { portState in
          // 35.2.2.9.3/.4: an end station adopts its neighbour's SRclassPriority and SRclassVID,
          // joining the attached network's SR domain -- so it is not a peer boundary (PFC on the
          // adopted priority is caught live by isSrpDomainBoundary).
          portState.srClassPriorityMap[domain.srClassID] = domain.srClassPriority
          portState.srpClassVID[domain.srClassID] = VLAN(vid: domain.srClassVID)
          portState.srpDomainBoundaryPort[domain.srClassID] = false
        }
      } else {
        let ingress = try findParticipant(for: contextIdentifier, port: port)
        // on a point-to-point link a peer priority change re-declares without a Leave, so supersede
        // the stale registration; on shared media keep coexisting peers (the derive handles many)
        if port.isPointToPoint { _supersedeStaleDomains(on: ingress, keeping: domain) }
        try _recomputeSrpDomainBoundary(
          participant: ingress,
          port: port,
          srClassID: domain.srClassID
        )
        if let bridge = controller?.bridge as? any MSRPAwareBridge<P> {
          await _applyPortFiltering(port: port, bridge: bridge)
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
    // asCapable is kept fresh by periodic() (1 s) and the per-indication resample, so plan straight
    // from the cache rather than re-query PTP for every port here (35.2.1).
    while !_pendingStreams.isEmpty {
      let streamID = _pendingStreams.removeFirst()
      let plan = _makeStreamPlan(streamID)
      do { try await _applyStreamPlan(plan) }
      catch { _logger.error("MSRP: recompute failed for stream \(streamID): \(error)") }
      // 10.3 a): the propagated declarations carry any New marking now, so consume it -- unless a
      // stale plan was abandoned (stream re-queued), where the replan still needs it.
      if !_pendingStreams.contains(streamID) { _receivedNew[streamID] = nil }
      // a stream that just reserved may have displaced lower-importance streams (Avnu §9.1);
      // queue them so they re-evaluate admission and declare Failed (drained in this loop)
      for displaced in plan.displacedStreams where displaced != streamID {
        _streamDidUpdate(displaced)
      }
    }
    _tcDetected.removeAll() // topology-change New marking applied to every re-derived stream
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
           ownDeclaration.isListenerReady
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
        if declarationType.isListenerReady {
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
        plan.listenerSourcePorts.insert(participant.port.id)
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

    var declaredTalkerPorts = Set<P.ID>()

    // 10.3 a): mark a propagated declaration New if it was received New, or a topology change
    // occurred on its ingress port (consumed after the drain, so a later refresh is a plain Join).
    let newPorts = _receivedNew[streamID] ?? []
    let talkerIsNew = newPorts.contains(boundTalker.0.port.id) ||
      _tcDetected.contains(boundTalker.0.port.id)
    let listenerIsNew = plan.listenerSourcePorts.contains {
      newPorts.contains($0) || _tcDetected.contains($0)
    }

    // per-hop latency is cached per port and refreshed only when the topology changes (a link flap
    // or STP transition calls invalidate()); it is NOT re-sampled every recompute, so ordinary gPTP
    // meanLinkDelay jitter cannot push the reported latency past its guarantee (35.2.2.8.6).
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
      // 35.2.2.8: a peer changed a FirstValue field of this registered stream; it stays Failed
      // (code 16, recorded in onJoinIndication) until the talker withdraws and re-declares cleanly.
      if _firstValueViolations[streamID]?.contains(boundTalker.0.port.id) == true {
        failure = MSRPFailure(
          systemID: _systemID, failureCode: .changeInFirstValueForRegisteredStreamID
        )
      }
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
          isNew: talkerIsNew, eventSource: .map
        )
      } else {
        try participant.join(
          attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
          attributeValue: boundTalker.1.makeAdvertise(accumulatedLatency: latency),
          isNew: talkerIsNew, eventSource: .map
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
        attributeValue: listenerValue, isNew: listenerIsNew, eventSource: .map
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
      if _portStates[participant.port.id]?.reservations[streamID] != desired {
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
      _portStates[participant.port.id]?.reservations[streamID] = desired
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

    // converge the group's MDB entries: egress Listener-Ready ports + (secure switch) the Talker's
    // p2p ingress admission port. A Failed talker reserves nothing, so its group is torn down.
    var groupPorts = [P.ID: P]()
    if boundTalker.1 is MSRPTalkerAdvertiseValue {
      // only ports whose per-port reservation was actually recorded; a CBS failure above leaves the
      // port unrecorded, so it is excluded here and retried on a later recompute
      for (participant, _) in plan.listenerPorts
        where _portStates[participant.port.id]?.reservations[streamID]?.isListenerReady == true
      {
        groupPorts[participant.port.id] = participant.port
      }
      if _configureIngressMdb, boundTalker.0.port.isPointToPoint {
        groupPorts[boundTalker.0.port.id] = boundTalker.0.port
      }
    }
    // a newer event re-marked the stream during the reservation awaits: skip the MDB reconcile and
    // let the next drain program it from a fresh plan (idempotent on the desired set)
    if _pendingStreams.contains(streamID) { return }
    // CBS idle-slope (above) and the group MDB entries (here) are deliberately reconciled in
    // separate passes, not interleaved in the old add-FDB-after-credit / remove-FDB-before-credit
    // order; the brief teardown under-credit window this allows is accepted.
    await _updateGroupReservations(
      streamID: streamID, params: boundTalker.1.dataFrameParameters, desired: groupPorts
    )
  }

  // No talker registered: withdraw every reservation and our own declarations for the stream.
  private func _withdrawStream(_ streamID: MSRPStreamID) async throws {
    // the Talker is gone: drop all group MDB entries (egress + secure-switch ingress admission)
    await _updateGroupReservations(streamID: streamID, params: nil, desired: [:])
    // 35.2.2.8: the talker withdrew, so a subsequent re-declaration starts clean (clears code 16)
    _firstValueViolations[streamID] = nil

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
    _portStates[portID]?.reservations[streamID] = nil
  }

  private func _reservationsToWithdraw(
    _ streamID: MSRPStreamID, keeping: Set<P.ID>
  ) -> [(P.ID, any MSRPTalkerValue)] {
    _portStates.compactMap { portID, portState in
      guard let applied = portState.reservations[streamID], !keeping.contains(portID)
      else { return nil }
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

    await _updateAsCapable(port: port)

    switch attributeType {
    case .talkerAdvertise:
      fallthrough
    case .talkerFailed:
      fallthrough
    case .listener:
      _streamDidUpdate((attributeValue as! any MSRPStreamIDRepresentable).streamID)
    case .domain:
      let domain = (attributeValue as! MSRPDomainValue)
      let ingress = try findParticipant(for: contextIdentifier, port: port)
      if await controller?.isEndStation == true {
        // 35.2.2.9: revert to a boundary only if no Domain for the class remains adopted; a peer
        // priority change withdraws the old value but leaves the new one registered (in-domain)
        let stillAdopted = ingress.findAttributes(
          attributeType: MSRPAttributeType.domain.rawValue, matching: .matchAnyIndex(domain.index)
        ).contains { ($0.1 as? MSRPDomainValue)?.srClassID == domain.srClassID }
        try withPortState(port: port) { $0.srpDomainBoundaryPort[domain.srClassID] = !stillAdopted }
      } else {
        // a bridge re-derives the boundary with this registration now withdrawn (35.2.1.4 h)
        try _recomputeSrpDomainBoundary(
          participant: ingress,
          port: port,
          srClassID: domain.srClassID
        )
        if let bridge = controller?.bridge as? any MSRPAwareBridge<P> {
          await _applyPortFiltering(port: port, bridge: bridge)
        }
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
    let toDeclare: (
      MSRPDomainValue?,
      MSRPDomainValue
    )? = try withPortState(port: participant.port) { portState in
      guard let domain = portState.getDomain(for: srClassID, defaultSRPVid: _srPVid) else {
        _logger
          .warning(
            "MSRP: port \(participant.port) not declaring domain for SR class \(srClassID) as no priority mapping found"
          )
        return nil
      }
      let previous = portState.declaredDomains[srClassID]
      guard previous != domain else { return nil }
      portState.declaredDomains[srClassID] = domain
      return (previous, domain)
    }

    guard let (previous, domain) = toDeclare else { return }
    // join() keys on identity, so a changed priority/VID would orphan the old value: withdraw the
    // superseded declaration first (35.2.4).
    if let previous {
      try? participant.leave(
        attributeType: MSRPAttributeType.domain.rawValue,
        attributeValue: previous,
        eventSource: .application
      )
    }
    _logger.info("MSRP: port \(participant.port) declaring domain \(domain)")
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

  // Avnu ProAV §9.3: cap registered Talker streams globally across all ports. Consulted before the
  // Registrar records a stream (via isRegistrationAllowed), so an over-limit stream is never
  // registered. An already-registered stream is always permitted (a re-declaration, or an
  // Advertise<->Failed change, must not be forbidden); the pair is one stream, not two.
  func _isTalkerRegistrationPermitted(streamID: MSRPStreamID) -> Bool {
    guard _maxTalkerAttributes > 0 else { return true }
    var streamIDs = Set<MSRPStreamID>()
    apply { participant in
      for type in [MSRPAttributeType.talkerAdvertise, MSRPAttributeType.talkerFailed] {
        for (_, value) in participant.findAttributes(
          attributeType: type.rawValue, matching: .matchAny
        ) {
          if let talker = value as? any MSRPTalkerValue { streamIDs.insert(talker.streamID) }
        }
      }
    }
    return streamIDs.contains(streamID) || streamIDs.count < _maxTalkerAttributes
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
