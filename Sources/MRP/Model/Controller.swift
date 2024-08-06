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

// MRP is a simple, fully distributed, many-to-many protocol, that supports
// efficient, reliable, and rapid declaration and registration of attributes by
// multiple participants on shared and virtual shared media. MRP also
// incorporates optimizations to speed attribute declarations and withdrawals
// on point-to-point media. Correctness of MRP operation is independent of the
// relative values of protocol timers, and the protocol design is based
// primarily on the exchange of idempotent protocol state rather than commands.

@preconcurrency
import AsyncExtensions
import Logging

actor Controller<P: Port> {
  private var periodicTransmissionTime: Duration {
    .seconds(1)
  }

  var leaveAllTime: Duration {
    let leaveAllTime = Double.random(in: LeaveAllTime..<(1.5 * LeaveAllTime))
    return Duration.seconds(leaveAllTime)
  }

  private var _applications = [UInt16: any Application<P>]()
  private(set) var ports = Set<P>()
  private var _rxTasks = [P.ID: Task<(), Error>]()
  private var _periodicTimers = [P.ID: Timer]()
  private let _administrativeControl = ManagedCriticalState(
    AdministrativeControl
      .normalParticipant
  )

  let bridge: any Bridge<P>
  var bridgeNotificationTask: Task<(), Error>?
  let logger: Logger

  public init(bridgePort: P, bridge: some Bridge<P>) async throws {
    ports = try await Set(bridge.getPorts())
    self.bridge = bridge
    var logger = Logger(label: "com.padl.SwiftMRP")
    logger.logLevel = .trace
    self.logger = logger
  }

  public func run() async throws {
    logger.debug("starting \(self)")
    try await _didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    for port in ports {
      try? await _didAdd(port: port)
    }
    bridgeNotificationTask = Task { try await _handleBridgeNotifications() }
  }

  public func shutdown() async throws {
    logger.debug("shutting down \(self)")
    for port in ports {
      try _didRemove(port: port)
    }
    bridgeNotificationTask?.cancel()
    bridgeNotificationTask = nil
  }

  var knownContextIdentifiers: Set<MAPContextIdentifier> {
    Set([MAPBaseSpanningTreeContext] + bridge.vlans.map { MAPContextIdentifier(vlan: $0) })
  }

  typealias MAPContextDictionary = [MAPContextIdentifier: MAPContext<P>]

  func context(for contextIdentifier: MAPContextIdentifier) -> MAPContext<P> {
    if contextIdentifier == MAPBaseSpanningTreeContext {
      ports
    } else {
      ports.filter { port in
        port.vlans.contains(VLAN(contextIdentifier: contextIdentifier))
      }
    }
  }

  var knownContexts: MAPContextDictionary {
    MAPContextDictionary(uniqueKeysWithValues: knownContextIdentifiers.map { contextIdentifier in
      (contextIdentifier, context(for: contextIdentifier))
    })
  }

  private func _applyContextIdentifierChanges(beforeAddingOrUpdating port: P) async throws {
    let addedContextIdentifiers: Set<MAPContextIdentifier>
    let removedContextIdentifiers: Set<MAPContextIdentifier>
    let updatedContextIdentifiers: Set<MAPContextIdentifier>

    if let existingPort = ports.first(where: { $0.id == port.id }) {
      addedContextIdentifiers = port.contextIdentifiers.subtracting(existingPort.contextIdentifiers)
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

    try _didUpdate(contextIdentifier: MAPBaseSpanningTreeContext, with: [port])

    for contextIdentifier in removedContextIdentifiers {
      try _didRemove(contextIdentifier: contextIdentifier, with: [port])
    }

    for contextIdentifier in updatedContextIdentifiers {
      try _didUpdate(contextIdentifier: contextIdentifier, with: [port])
    }

    for contextIdentifier in addedContextIdentifiers {
      try await _didAdd(contextIdentifier: contextIdentifier, with: [port])
    }
  }

  private func _applyContextIdentifierChanges(beforeRemoving port: P) throws {
    let removedContextIdentifiers: Set<MAPContextIdentifier>

    guard let existingPort = ports.first(where: { $0.id == port.id }) else { return }
    removedContextIdentifiers = existingPort.contextIdentifiers.subtracting(port.contextIdentifiers)

    for contextIdentifier in [MAPBaseSpanningTreeContext] + removedContextIdentifiers {
      try _didRemove(contextIdentifier: contextIdentifier, with: [port])
    }
  }

  private func _didAdd(port: P) async throws {
    logger.debug("added port \(port)")

    for application in _applications {
      try? port.add(
        filter: application.value.groupMacAddress,
        etherType: application.value.etherType
      )
    }

    _startRx(port: port)
    _startTx(port: port)

    try await _applyContextIdentifierChanges(beforeAddingOrUpdating: port)
    ports.insert(port)
  }

  private func _didRemove(port: P) throws {
    logger.debug("removed port \(port)")

    for application in _applications {
      try? port.remove(
        filter: application.value.groupMacAddress,
        etherType: application.value.etherType
      )
    }
    _stopTx(port: port)
    _stopRx(port: port)

    try _applyContextIdentifierChanges(beforeRemoving: port)
    ports.remove(port)
  }

  private func _didUpdate(port: P) async throws {
    logger.debug("updated port \(port)")

    try await _applyContextIdentifierChanges(beforeAddingOrUpdating: port)
    ports.update(with: port)
  }

  private func _handleBridgeNotifications() async throws {
    for try await notification in bridge.notifications {
      do {
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
          .info("failed to handle notification for port \(notification.port): \(error)")
      }
    }
  }

  func periodicEnabled() {
    logger.trace("enabled periodic timer")
    _periodicTimers.forEach { $0.value.start(interval: periodicTransmissionTime) }
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

  deinit {
    bridgeNotificationTask?.cancel()
  }

  func register(application: some Application<P>) throws {
    guard _applications[application.etherType] == nil
    else { throw MRPError.applicationAlreadyRegistered }
    _applications[application.etherType] = application
    logger.info("registered application \(application)")
  }

  func deregister(application: some Application<P>) throws {
    guard _applications[application.etherType] == nil
    else { throw MRPError.applicationNotFound }
    _applications.removeValue(forKey: application.etherType)
    logger.info("deregistered application \(application)")
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

  private func _startRx(port: P) {
    _rxTasks[port.id] = Task { @Sendable in
      for try await packet in try await port.rxPackets {
        try await _applications[packet.etherType]?.rx(packet: packet, from: port)
      }
    }
  }

  private func _startTx(port: P) {
    var periodicTimer = _periodicTimers[port.id]
    if periodicTimer == nil {
      periodicTimer = Timer {
        try await self._apply { @Sendable application in
          try await application.periodic()
        }
      }
    }
    periodicTimer!.start(interval: periodicTransmissionTime)
  }

  private func _stopRx(port: P) {
    _rxTasks[port.id]?.cancel()
    _rxTasks[port.id] = nil
  }

  private func _stopTx(port: P) {
    _periodicTimers[port.id]?.stop()
  }
}
