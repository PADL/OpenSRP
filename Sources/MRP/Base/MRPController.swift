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
#if canImport(FlyingFox)
import FlyingFox
#endif
import IEEE802
import Logging
import ServiceLifecycle

public actor MRPController<P: Port>: Service, CustomStringConvertible, Sendable {
  typealias MAPContextDictionary = [MAPContextIdentifier: MAPContext<P>]

  let bridge: any Bridge<P>
  let logger: Logger
  var ports: Set<P> { Set(_ports.values) }
  let timerConfiguration: MRPTimerConfiguration

  private var _applications = [UInt16: any Application<P>]()
  private var _ports = [P.ID: P]()
  private var _periodicTimers = [P.ID: Timer]()
  private var _administrativeControl = AdministrativeControl.normalParticipant
  private var _taskGroup: ThrowingTaskGroup<(), Error>?
  private let _rxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)>
  private let _portExclusions: Set<String>
  #if canImport(FlyingFox)
  private var _httpServer: HTTPServer?
  #endif

  public init(
    bridge: some Bridge<P>,
    logger: Logger,
    timerConfiguration: MRPTimerConfiguration = .init(),
    portExclusions: Set<String> = [],
    restServerPort: UInt16? = nil
  ) async throws {
    logger
      .debug(
        "initializing MRP with bridge \(bridge), timers \(timerConfiguration), port exclusions \(portExclusions)"
      )
    self.bridge = bridge
    self.logger = logger
    self.timerConfiguration = timerConfiguration
    _rxPackets = try bridge.rxPackets
    _portExclusions = portExclusions
    #if canImport(FlyingFox)
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
        #if canImport(FlyingFox)
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
    // FIXME: there appears to be a crash here
    _taskGroup?.cancelAll()
    #if canImport(FlyingFox)
    await _httpServer?.stop()
    #endif
    try? await bridge.shutdown(controller: self)
    for port in ports {
      try? _didRemove(port: port)
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

    if let existingPort = ports.first(where: { $0.id == port.id }) {
      addedContextIdentifiers = port.contextIdentifiers
        .subtracting(existingPort.contextIdentifiers)
      removedContextIdentifiers = existingPort.contextIdentifiers
        .subtracting(port.contextIdentifiers)
      updatedContextIdentifiers = existingPort.contextIdentifiers
        .intersection(port.contextIdentifiers)
    } else {
      addedContextIdentifiers = port.contextIdentifiers
      removedContextIdentifiers = []
      updatedContextIdentifiers = []
    }

    precondition(!addedContextIdentifiers.contains(MAPBaseSpanningTreeContext))
    precondition(!removedContextIdentifiers.contains(MAPBaseSpanningTreeContext))

    logger
      .trace(
        "applying context identifier changes prior to \(isNewPort ? "adding" : "updating") port \(port): removed \(removedContextIdentifiers) updated \(updatedContextIdentifiers) added \(addedContextIdentifiers)"
      )

    for contextIdentifier in removedContextIdentifiers {
      try _didRemove(contextIdentifier: contextIdentifier, with: [port])
    }

    for contextIdentifier in updatedContextIdentifiers
      .union(isNewPort ? [] : [MAPBaseSpanningTreeContext])
    {
      try _didUpdate(contextIdentifier: contextIdentifier, with: [port])
    }

    for contextIdentifier in addedContextIdentifiers
      .union(isNewPort ? [MAPBaseSpanningTreeContext] : [])
    {
      try await _didAdd(contextIdentifier: contextIdentifier, with: [port])
    }
  }

  private func _applyContextIdentifierChanges(beforeRemoving port: P) throws {
    let removedContextIdentifiers: Set<MAPContextIdentifier>

    guard let existingPort = ports.first(where: { $0.id == port.id }) else { return }
    removedContextIdentifiers = existingPort.contextIdentifiers.subtracting(port.contextIdentifiers)

    logger
      .trace(
        "applying context identifier changes prior to removing port \(port): \(removedContextIdentifiers)"
      )

    for contextIdentifier in [MAPBaseSpanningTreeContext] + removedContextIdentifiers {
      try _didRemove(contextIdentifier: contextIdentifier, with: [port])
    }
  }

  private func _didAdd(port: P) async throws {
    logger.debug("added port \(port.id): \(port)")

    if timerConfiguration.periodicTime != .zero { _startPeriodicTimer(port: port) }

    try await _applyContextIdentifierChanges(beforeAddingOrUpdating: port, isNewPort: true)
    _ports[port.id] = port
  }

  private func _didRemove(port: P) throws {
    logger.debug("removed port \(port.id): \(port)")

    if timerConfiguration.periodicTime != .zero { _stopPeriodicTimer(port: port) }

    try _applyContextIdentifierChanges(beforeRemoving: port)
    _ports[port.id] = nil
  }

  private func _didUpdate(port: P) async throws {
    logger.debug("updated port \(port.id): \(port)")

    try await _applyContextIdentifierChanges(beforeAddingOrUpdating: port, isNewPort: false)
    _ports[port.id] = port
  }

  private func _handleBridgeNotifications() async throws {
    for try await notification in bridge.notifications {
      do {
        if _portExclusions.contains(notification.port.name) { continue }
        switch notification {
        case let .added(port):
          try await ports.contains(port) ? _didUpdate(port: port) : _didAdd(port: port)
        case let .removed(port):
          try _didRemove(port: port)
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
    _periodicTimers.forEach { $0.value.start(interval: timerConfiguration.periodicTime) }
  }

  func periodicDisabled() {
    logger.trace("disabled periodic timer")
    _periodicTimers.forEach { $0.value.stop() }
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
    #if canImport(FlyingFox)
    if let application = application as? any RestApiApplication, let _httpServer {
      try await application.registerRestApiHandlers(for: _httpServer)
    }
    #endif
    logger.info("registered application \(application.name)")
  }

  func deregister(application: some Application<P>) async throws {
    guard _applications[application.etherType] == nil
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
  ) throws {
    for application in _applications.values {
      try application.didUpdate(contextIdentifier: contextIdentifier, with: context)
    }
  }

  private func _didRemove(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) throws {
    for application in _applications.values {
      try application.didRemove(contextIdentifier: contextIdentifier, with: context)
    }
  }

  private func _startPeriodicTimer(port: P) {
    precondition(timerConfiguration.periodicTime != .zero)
    logger.debug("controller starting periodic timer on port \(port)")
    var periodicTimer = _periodicTimers[port.id]
    if periodicTimer == nil {
      periodicTimer = Timer(label: "periodictimer") {
        try await self._apply { @Sendable application in
          try await application.periodic()
        }
      }
    }
    periodicTimer!.start(interval: timerConfiguration.periodicTime)
  }

  private func _stopPeriodicTimer(port: P) {
    precondition(timerConfiguration.periodicTime != .zero)
    logger.debug("controller stopping periodic timer on port \(port)")
    _periodicTimers[port.id]?.stop()
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

#if canImport(FlyingFox)
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
