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
  private var _rxTasks = [P: Task<(), Error>]()
  private var _periodicTimers = [P: Timer]()
  private let _administrativeControl = ManagedCriticalState(
    AdministrativeControl
      .normalParticipant
  )

  let portMonitor: any PortMonitor<P>
  var portNotificationTask: Task<(), Error>?
  let logger: Logger

  public init(portMonitor: some PortMonitor<P>) async throws {
    ports = try await Set(portMonitor.ports)
    self.portMonitor = portMonitor
    var logger = Logger(label: "com.padl.SwiftMRP")
    logger.logLevel = .trace
    self.logger = logger
  }

  public func run() async throws {
    logger.debug("starting \(self)")
    for port in ports {
      try? await _didAdd(port: port)
    }
    portNotificationTask = Task { try await _handlePortNotifications() }
  }

  public func shutdown() async throws {
    logger.debug("shutting down \(self)")
    for port in ports {
      await _didRemove(port: port)
    }
    portNotificationTask?.cancel()
    portNotificationTask = nil
  }

  private func _didAdd(port: P) async throws {
    logger.debug("added port \(port)")

    ports.insert(port)
    for application in _applications {
      try? port.addFilter(
        for: application.value.groupMacAddress,
        etherType: application.value.etherType
      )
    }

    _rxTasks[port] = Task { @Sendable in
      for try await packet in try await port.rxPackets {
        try await _applications[packet.etherType]?.rx(packet: packet, from: port)
      }
    }
    var periodicTimer = _periodicTimers[port]
    if periodicTimer == nil {
      periodicTimer = Timer {
        try await self.apply { @Sendable application in
          try await application.periodic()
        }
      }
    }
    periodicTimer!.start(interval: periodicTransmissionTime)
    try? await apply(
      with: PortNotification.added(port),
      (any Application<P>).onPortNotification(_:)
    )
  }

  private func _didRemove(port: P) async {
    logger.debug("removed port \(port)")

    for application in _applications {
      try? port.removeFilter(
        for: application.value.groupMacAddress,
        etherType: application.value.etherType
      )
    }
    _rxTasks[port]?.cancel()
    _rxTasks[port] = nil
    ports.remove(port)
    _periodicTimers[port]?.stop()
    try? await apply(
      with: PortNotification.removed(port),
      (any Application<P>).onPortNotification(_:)
    )
  }

  private func _didUpdate(port: P) async {
    logger.debug("updated port \(port)")

    ports.update(with: port)
    try? await apply(
      with: PortNotification.changed(port),
      (any Application<P>).onPortNotification(_:)
    )
  }

  private func _handlePortNotifications() async throws {
    for try await portNotification in portMonitor.notifications {
      switch portNotification {
      case let .added(port):
        try? await _didAdd(port: port)
      case let .removed(port):
        await _didRemove(port: port)
      case let .changed(port):
        await _didUpdate(port: port)
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

  typealias MADApplyFunction = (any Application<P>) async throws -> ()

  @Sendable
  private func apply(_ block: MADApplyFunction) async rethrows {
    for application in _applications {
      try await block(application.value)
    }
  }

  typealias MADContextSpecificApplyFunction<T> = (any Application<P>) -> (T) async throws -> ()

  private func apply<T>(
    with arg: T,
    _ block: MADContextSpecificApplyFunction<T>
  ) async throws {
    try await apply { application in
      try await block(application)(arg)
    }
  }

  deinit {
    portNotificationTask?.cancel()
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
}
