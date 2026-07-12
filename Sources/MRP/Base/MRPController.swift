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

// MRP is a simple, fully distributed, many-to-many protocol, that supports
// efficient, reliable, and rapid declaration and registration of attributes by
// multiple participants on shared and virtual shared media. MRP also
// incorporates optimizations to speed attribute declarations and withdrawals
// on point-to-point media. Correctness of MRP operation is independent of the
// relative values of protocol timers, and the protocol design is based
// primarily on the exchange of idempotent protocol state rather than commands.

import AsyncExtensions
#if RestAPI
import FlyingFox
#endif
import IEEE802
import Logging
import ServiceLifecycle
import Synchronization

public struct MRPFlags: OptionSet, Sendable {
  public typealias RawValue = UInt8

  public let rawValue: RawValue

  public init(rawValue: RawValue) { self.rawValue = rawValue }

  public static let forceFullParticipant = Self(rawValue: 1 << 0)

  public static let defaultFlags: Self = []
}

public actor MRPController<P: Port>: Service, CustomStringConvertible, Sendable {
  typealias MAPContextDictionary = [MAPContextIdentifier: MAPContext<P>]

  let bridge: any Bridge<P>
  let logger: Logger
  var ports: Set<P> { Set(_ports.values) }
  let timerConfiguration: MRPTimerConfiguration
  let flags: MRPFlags

  private var _applications = [UInt16: any Application<P>]()
  private var _ports = [P.ID: P]()
  // Snapshot of each port's context identifiers taken when it was last added or
  // updated. A platform port may read live VLAN state, so the stored port would
  // already reflect a change and the delta would come up empty; diffing against
  // this snapshot lets a runtime VLAN add be detected as added, not updated.
  private var _portContextIdentifiers = [P.ID: Set<MAPContextIdentifier>]()
  // Last-seen MRP-relevant state per port. Like _portContextIdentifiers: the port reads live link
  // state, so diff against this value snapshot, not a fresh PortMRPState of the stored port.
  private var _portMRPState = [P.ID: PortMRPState]()
  // last seen spanning-tree status per port, for topology-change (Flush!) detection. This is
  // the role, polled from the STP source (mstpd); the per-port Forwarding *state* used to gate
  // declarations (35.1.3.1) is read synchronously from the netlink port snapshot in the
  // applications, so the recompute never takes an actor transition.
  private var _stpPortStatus = [P.ID: STPPortStatus]()
  // Counts received-PDU propagations still in flight (a Join/Leave indication scheduled but not yet
  // applied to the egress Participants). A tx opportunity parks on this barrier until the count
  // returns to zero, so one received PDU coalesces into one transmitted MRPDU rather than
  // splitting.
  nonisolated let _propagationBarrier = CountedBarrier()
  private var _periodicTimer: Timer?
  private var _stpPollTimer: Timer?
  private var _taskGroup: ThrowingTaskGroup<(), Error>?
  private let _rxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)>
  private let _portExclusions: Set<String>
  #if RestAPI
  private var _httpServer: HTTPServer?
  #endif

  public init(
    bridge: some Bridge<P>,
    logger: Logger,
    timerConfiguration: MRPTimerConfiguration = .init(),
    portExclusions: Set<String> = [],
    restServerPort: UInt16? = nil,
    flags: MRPFlags = .defaultFlags
  ) async throws {
    logger
      .debug(
        "initializing MRP with bridge \(bridge), timers \(timerConfiguration), port exclusions \(portExclusions)"
      )
    self.bridge = bridge
    self.logger = logger
    self.timerConfiguration = timerConfiguration
    self.flags = flags
    _rxPackets = try bridge.rxPackets
    _portExclusions = portExclusions
    #if RestAPI
    if let restServerPort {
      let httpServer = HTTPServer(port: restServerPort)
      await registerDefaultRestApiHandlers(for: httpServer)
      _httpServer = httpServer
    } else {
      _httpServer = nil
    }
    #endif
  }

  public nonisolated var description: String {
    "MRPController(bridge: \(bridge))"
  }

  private func _run() async throws {
    logger.info("starting MRP for bridge \(bridge)")

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        _taskGroup = group
        group.addTask { @Sendable in try await self._handleBridgeNotifications() }
        group.addTask { @Sendable [self] in
          // will block until starting set of ports is initialized
          try await bridge.run(controller: self)
          try await _handleRxPackets()
        }
        #if RestAPI
        if let _httpServer {
          group.addTask { @Sendable in try await _httpServer.run() }
        }
        #endif
        for try await _ in group {}
      }
    } catch {
      logger.info("MRP event loop terminated: \(error)")
    }
  }

  private func _shutdown() async {
    logger.info("stopping MRP for bridge \(bridge)")
    _taskGroup?.cancelAll()
    #if RestAPI
    await _httpServer?.stop()
    #endif
    // let applications withdraw programmed hardware state (MSRP dynamic-reservation MDB entries)
    // while the bridge is still usable, before its netlink sockets are torn down below
    for application in _applications.values {
      await application.shutdown()
    }
    try? await bridge.shutdown(controller: self)
    for port in ports {
      try? await _didRemove(port: port)
    }
  }

  public func run() async throws {
    try await cancelWhenGracefulShutdown {
      try await self._run()
    }
    await _shutdown()
  }

  public func port(with id: P.ID) throws -> P {
    guard let port = ports.first(where: { $0.id == id }) else {
      throw MRPError.portNotFound
    }
    return port
  }

  var knownContextIdentifiers: Set<MAPContextIdentifier> {
    get async {
      await Set(
        [MAPBaseSpanningTreeContext] + bridge.getVlans(controller: self)
          .map { MAPContextIdentifier(vlan: $0) }
      )
    }
  }

  func context(for contextIdentifier: MAPContextIdentifier) async -> MAPContext<P> {
    if contextIdentifier == MAPBaseSpanningTreeContext {
      ports
    } else {
      ports.filter { port in
        port.vlans.contains(VLAN(contextIdentifier: contextIdentifier))
      }
    }
  }

  var knownContexts: MAPContextDictionary {
    get async {
      await MAPContextDictionary(
        uniqueKeysWithValues: knownContextIdentifiers
          .asyncMap { @Sendable contextIdentifier in
            await (contextIdentifier, context(for: contextIdentifier))
          }
      )
    }
  }

  private var _nonBaseContextsSupported: Bool {
    // if at least one application supports non-base spanning tree contexts, then we need to
    // allocate a context per VID
    var nonBaseContextsSupported = false
    _apply { application in
      if application.nonBaseContextsSupported {
        nonBaseContextsSupported = true
      }
    }
    return nonBaseContextsSupported
  }

  private func _applyContextIdentifierChanges(
    beforeAddingOrUpdating port: P,
    isNewPort: Bool
  ) async throws {
    let addedContextIdentifiers: Set<MAPContextIdentifier>
    let removedContextIdentifiers: Set<MAPContextIdentifier>
    let updatedContextIdentifiers: Set<MAPContextIdentifier>

    // Diff against the snapshot from when the port was last seen, not against the
    // stored port: a platform port may read live VLAN state, so the stored port
    // already reflects the change (a runtime VLAN add would otherwise look
    // "updated", not "added", and applications that only originate on add miss it).
    let previousContextIdentifiers = _portContextIdentifiers[port.id] ?? []
    let currentContextIdentifiers = port.contextIdentifiers
    addedContextIdentifiers = currentContextIdentifiers.subtracting(previousContextIdentifiers)
    removedContextIdentifiers = previousContextIdentifiers.subtracting(currentContextIdentifiers)
    updatedContextIdentifiers = previousContextIdentifiers.intersection(currentContextIdentifiers)

    precondition(!addedContextIdentifiers.contains(MAPBaseSpanningTreeContext))
    precondition(!removedContextIdentifiers.contains(MAPBaseSpanningTreeContext))

    logger
      .trace(
        "applying context identifier changes prior to \(isNewPort ? "adding" : "updating") port \(port): removed \(removedContextIdentifiers) updated \(updatedContextIdentifiers) added \(addedContextIdentifiers)"
      )

    for contextIdentifier in removedContextIdentifiers {
      try await _didRemove(contextIdentifier: contextIdentifier, with: [port])
    }

    for contextIdentifier in updatedContextIdentifiers
      .union(isNewPort ? [] : [MAPBaseSpanningTreeContext])
    {
      try await _didUpdate(contextIdentifier: contextIdentifier, with: [port])
    }

    for contextIdentifier in addedContextIdentifiers
      .union(isNewPort ? [MAPBaseSpanningTreeContext] : [])
    {
      try await _didAdd(contextIdentifier: contextIdentifier, with: [port])
    }
  }

  private func _applyContextIdentifierChanges(beforeRemoving port: P) async throws {
    guard _ports[port.id] != nil else { return }
    let previousContextIdentifiers = _portContextIdentifiers[port.id] ?? []
    let removedContextIdentifiers = previousContextIdentifiers.subtracting(port.contextIdentifiers)

    logger
      .trace(
        "applying context identifier changes prior to removing port \(port): \(removedContextIdentifiers)"
      )

    for contextIdentifier in [MAPBaseSpanningTreeContext] + removedContextIdentifiers {
      try await _didRemove(contextIdentifier: contextIdentifier, with: [port])
    }
  }

  func _didAdd(port: P) async throws {
    logger.debug("added port \(port.id): \(port)")

    if timerConfiguration.periodicTime != .zero { _startPeriodicTimer() }

    try await _applyContextIdentifierChanges(beforeAddingOrUpdating: port, isNewPort: true)
    _ports[port.id] = port
    _portMRPState[port.id] = PortMRPState(port)
    _portContextIdentifiers[port.id] = port.contextIdentifiers
    await _checkTopologyChange(port: port)
  }

  private func _didRemove(port: P) async throws {
    logger.debug("removed port \(port.id): \(port)")

    // 10.3: removal is also removal from the Forwarding set -- but only a Port that was in the set
    // had declarations to withdraw. Withdraw the other Ports' declarations that depended on this
    // Port's registrations before its participant is torn down; the survivors transmit the Leaves.
    if _portMRPState[port.id].map({ _isForwarding($0.stpPortState) }) ?? false {
      await _apply { application in
        try? await application.didChangeForwardingState(
          port: port, isForwarding: false, for: MAPBaseSpanningTreeContext
        )
      }
    }

    try await _applyContextIdentifierChanges(beforeRemoving: port)
    _ports[port.id] = nil
    _portMRPState[port.id] = nil
    _portContextIdentifiers[port.id] = nil
    _stpPortStatus[port.id] = nil

    if _ports.isEmpty { _stopStpPollTimer() }
    if timerConfiguration.periodicTime != .zero { _stopPeriodicTimer() }
  }

  // The subset of a port's properties MRP reacts to. Equatable so a no-op netlink update (e.g. a
  // statistics refresh) can be told apart from a real carrier/STP/VLAN/link change.
  private struct PortMRPState: Equatable {
    let isOperational, isEnabled, isPointToPoint: Bool
    let stpPortState: STPPortState?
    let pvid: UInt16?
    let vlans: Set<VLAN>
    let mtu, linkSpeed: UInt

    init(_ port: some Port) {
      isOperational = port.isOperational
      isEnabled = port.isEnabled
      isPointToPoint = port.isPointToPoint
      stpPortState = port.stpPortState
      pvid = port.pvid
      vlans = port.vlans
      mtu = port.mtu
      linkSpeed = port.linkSpeed
    }
  }

  // Forwarding-set membership, matching BaseApplication._isForwarding: an unknown (nil/AF_UNSPEC)
  // STP state counts as Forwarding, for bridges without STP integration.
  private func _isForwarding(_ stpPortState: STPPortState?) -> Bool {
    stpPortState.map { $0 == .forwarding } ?? true
  }

  func _didUpdate(port: P) async throws {
    // The STP Port Role is not part of PortMRPState (it comes from an async mstpd poll, not the
    // netlink port snapshot), so a role-only transition -- Designated -> Root with unchanged
    // forwarding state -- would be gated out below and miss its Re-declare! (10.7.5.3). Check it
    // first; _checkTopologyChange caches the role (_stpPortStatus) and acts only on a transition.
    await _checkTopologyChange(port: port)

    // Act only on a real MRP-relevant change, not a netlink no-op (e.g. stats refresh). Compare
    // against the last snapshot: re-deriving from the stored port reads the same live cache.
    let previousState = _portMRPState[port.id]
    let state = PortMRPState(port)
    if previousState == state { return }
    logger.debug("updated port \(port.id): \(port)")

    // 10.3 NOTE / 11.2.1.2: a Port removed from the Forwarding set has left the active topology, so
    // it transmits a Leave for every attribute it had declared. Test the set exactly as propagation
    // does (BaseApplication._isForwarding, nil-lenient) so a declaration made while nil-state is
    // withdrawn, and a nil (AF_UNSPEC) snapshot -- still in the set -- is not treated as leaving.
    // 10.3: the Port entered or left the Forwarding set (only on a real transition, not first sight).
    let nowForwarding = _isForwarding(state.stpPortState)
    if let previousState, _isForwarding(previousState.stpPortState) != nowForwarding {
      await _apply { application in
        try? await application.didChangeForwardingState(
          port: port, isForwarding: nowForwarding, for: MAPBaseSpanningTreeContext
        )
      }
    }

    try await _applyContextIdentifierChanges(beforeAddingOrUpdating: port, isNewPort: false)
    _ports[port.id] = port
    _portMRPState[port.id] = state
    _portContextIdentifiers[port.id] = port.contextIdentifiers
  }

  // On a port event, poll the bridge's STP role and act on a role transition. Soft no-op when the
  // bridge has no STP integration.
  //   - into Designated (10.7.5.2): a topology change -> Flush!, rapidly deregistering this port's
  //     attributes across all applications so they re-register.
  //   - Designated -> Root/Alternate (10.7.5.3): Re-declare!, rapidly re-declaring this port's
  //     registered attributes rather than waiting for the next LeaveAll.
  private func _checkTopologyChange(port: P) async {
    guard let status = await bridge.getStpPortStatus(port: port) else { return }
    // the poll suspends: bail if the port was removed meanwhile (avoid resurrecting its
    // cache entry / flushing a gone port). The cache read-modify-write below is await-free.
    guard _ports[port.id] != nil else { return }
    // mstpd answered, so STP is present: keep polling the role. A role-only change has no netlink
    // signal, so otherwise its Re-declare! would wait for an unrelated port event (10.7.5.3).
    _startStpPollTimer()
    let previousRole = _stpPortStatus[port.id]?.role
    _stpPortStatus[port.id] = status
    // 10.7.5.2: Flush! only on Root/Alternate -> Designated. A port coming up from disabled/down
    // (or first seen) has nothing stale to flush, so don't churn registrations on link flap.
    if status.role == .designated, previousRole == .root || previousRole == .alternate {
      logger.debug("MRP: port \(port.id) became STP Designated (state \(status.state)); flushing")
      await _apply { application in
        try? await application.flush(for: MAPBaseSpanningTreeContext, port: port)
      }
    } else if previousRole == .designated, status.role == .root || status.role == .alternate {
      logger
        .debug("MRP: port \(port.id) left STP Designated for \(status.role); redeclaring")
      await _apply { application in
        try? await application.redeclare(for: MAPBaseSpanningTreeContext, port: port)
      }
    }
  }

  private func _handleBridgeNotifications() async throws {
    for try await notification in bridge.notifications {
      do {
        if _portExclusions.contains(notification.port.name) { continue }
        switch notification {
        case let .added(port):
          try await ports.contains(port) ? _didUpdate(port: port) : _didAdd(port: port)
        case let .removed(port):
          try await _didRemove(port: port)
        case let .changed(port):
          try await _didUpdate(port: port)
        }
      } catch {
        logger
          .error("failed to handle bridge notification on \(notification.port): \(error)")
      }
    }
  }

  private func _handleRxPackets() async throws {
    for try await (id, packet) in _rxPackets {
      guard let port = _ports[id] else {
        logger.debug("port \(id) not found, skipping")
        continue
      }

      // find the application for this ethertype
      guard let application = _applications[packet.etherType] else {
        logger.debug("application 0x\(packet.etherType) on port \(port) not found, skipping")
        continue
      }

      do {
        try await application.rx(packet: packet, from: port)
      } catch {
        logger.error("failed to process packet \(packet) from port \(port): \(error)")
      }
    }
  }

  func periodicEnabled() {
    logger.trace("enabled periodic timer")
    _periodicTimer?.start(interval: timerConfiguration.periodicTime)
  }

  func periodicDisabled() {
    logger.trace("disabled periodic timer")
    _periodicTimer?.stop()
  }

  typealias MADApplyFunction = (any Application<P>) throws -> ()

  private func _apply(_ block: MADApplyFunction) rethrows {
    for application in _applications {
      try block(application.value)
    }
  }

  typealias AsyncMADApplyFunction = (any Application<P>) async throws -> ()

  @Sendable
  private func _apply(_ block: AsyncMADApplyFunction) async rethrows {
    for application in _applications {
      try await block(application.value)
    }
  }

  typealias MADContextSpecificApplyFunction<T> = (any Application<P>) throws -> (T) throws -> ()

  private func _apply<T>(
    with arg: T,
    _ block: MADContextSpecificApplyFunction<T>
  ) rethrows {
    try _apply { application in
      try block(application)(arg)
    }
  }

  typealias AsyncMADContextSpecificApplyFunction<T> = (any Application<P>) throws
    -> (T) async throws -> ()

  private func _apply<T>(
    with arg: T,
    _ block: AsyncMADContextSpecificApplyFunction<T>
  ) async rethrows {
    try await _apply { application in
      try await block(application)(arg)
    }
  }

  func register(application: some Application<P>) async throws {
    guard _applications[application.etherType] == nil
    else { throw MRPError.applicationAlreadyRegistered }
    try await bridge.register(
      groupAddress: application.groupAddress,
      etherType: application.etherType,
      controller: self
    )
    _applications[application.etherType] = application
    #if RestAPI
    if let application = application as? any RestApiApplication, let _httpServer {
      try await application.registerRestApiHandlers(for: _httpServer)
    }
    #endif
    logger.info("registered application \(application.name)")
  }

  func deregister(application: some Application<P>) async throws {
    guard _applications[application.etherType] != nil
    else { throw MRPError.unknownApplication }
    _applications.removeValue(forKey: application.etherType)
    try? await bridge.deregister(
      groupAddress: application.groupAddress,
      etherType: application.etherType,
      controller: self
    )
    logger.info("deregistered application \(application.name)")
  }

  private func _didAdd(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    for application in _applications.values {
      try await application.didAdd(contextIdentifier: contextIdentifier, with: context)
    }
  }

  private func _didUpdate(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    for application in _applications.values {
      try await application.didUpdate(contextIdentifier: contextIdentifier, with: context)
    }
  }

  private func _didRemove(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    for application in _applications.values {
      try await application.didRemove(contextIdentifier: contextIdentifier, with: context)
    }
  }

  private func _startPeriodicTimer() {
    precondition(timerConfiguration.periodicTime != .zero)
    guard _periodicTimer == nil else { return }
    logger.debug("controller starting periodic timer")
    _periodicTimer = Timer(label: "periodictimer") { [weak self] in
      guard let self else { return }
      try await _apply { @Sendable application in
        // every application gets the 1 s tick: MVRP/MMRP re-transmit (PeriodicTransmission), MSRP
        // does not (Avnu §9.1 / 10.7.10) but uses it to resample gPTP-derived state
        try await application.periodic(for: nil)
      }
      await _restartPeriodicTimer()
    }
    _periodicTimer!.start(interval: timerConfiguration.periodicTime)
  }

  private func _restartPeriodicTimer() {
    _periodicTimer?.start(interval: timerConfiguration.periodicTime)
  }

  private func _stopPeriodicTimer() {
    precondition(timerConfiguration.periodicTime != .zero)
    guard _ports.isEmpty else { return }
    logger.debug("controller stopping periodic timer")
    _periodicTimer?.stop()
    _periodicTimer = nil
  }

  // Poll the STP role of every port on a cadence and act on a transition via _checkTopologyChange.
  // Only running once mstpd has answered (see _checkTopologyChange), so non-STP bridges don't poll.
  private func _startStpPollTimer() {
    guard _stpPollTimer == nil else { return }
    logger.debug("controller starting STP role poll timer")
    _stpPollTimer = Timer(label: "stppolltimer") { [weak self] in
      guard let self else { return }
      await _pollStpTopology()
    }
    _stpPollTimer!.start(interval: timerConfiguration.stpPollTime)
  }

  private func _pollStpTopology() async {
    for port in _ports.values {
      await _checkTopologyChange(port: port)
    }
    guard !_ports.isEmpty else {
      _stpPollTimer = nil
      return
    }
    _stpPollTimer?.start(interval: timerConfiguration.stpPollTime)
  }

  private func _stopStpPollTimer() {
    _stpPollTimer?.stop()
    _stpPollTimer = nil
  }

  public func application<T: Application>(for etherType: UInt16) throws -> T {
    guard let application = _applications[etherType] as? T else {
      throw MRPError.unknownApplication
    }
    return application
  }

  public var isEndStation: Bool {
    _ports.count < 2
  }
}

#if RestAPI
fileprivate extension MRPController {
  func registerDefaultRestApiHandlers(for httpServer: HTTPServer) async {
    let deviceHandler = DeviceHandler(controller: self)
    await httpServer.appendRoute("GET /api/*", to: deviceHandler)

    let mrpHandler = MRPHandler(controller: self)
    await httpServer.appendRoute("GET /api/avb/mrp", to: mrpHandler)
    await httpServer.appendRoute("GET /api/avb/mrp/*", to: mrpHandler)
  }
}
#endif
