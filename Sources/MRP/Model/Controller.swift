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

actor Controller<P: Port> {
  private var periodicTransmissionTime: Duration {
    .seconds(1)
  }

  var leaveAllTime: Duration {
    let leaveAllTime = Double.random(in: LeaveAllTime..<(1.5 * LeaveAllTime))
    return Duration.seconds(leaveAllTime)
  }

  private var applications = [UInt16: any Application<P>]()
  private(set) var ports = Set<P>()
  private var rxTasks = [P: Task<(), Error>]()
  private var periodicTimers = [P: Timer]()
  private let _administrativeControl = ManagedCriticalState(
    AdministrativeControl
      .normalParticipant
  )

  let portMonitor: any PortMonitor<P>
  var portNotificationTask: Task<(), Error>!

  init(portMonitor: some PortMonitor<P>) async throws {
    self.portMonitor = portMonitor

    ports = try await Set(portMonitor.ports)
    portNotificationTask = Task { try await _handlePortNotifications() }
  }

  private func _handlePortNotifications() async throws {
    for try await portNotification in portMonitor.notifications {
      switch portNotification {
      case let .added(port):
        ports.insert(port)
        rxTasks[port] = Task { @Sendable in
          for try await packet in port.rxPackets {
            try await applications[packet.etherType]?.rx(packet: packet, from: port)
          }
        }
        var periodicTimer = periodicTimers[port]
        if periodicTimer == nil {
          periodicTimer = Timer {
            try await self.apply { @Sendable application in
              try await application.periodic()
            }
          }
        }
        periodicTimer!.start(interval: periodicTransmissionTime)
      case let .removed(port):
        rxTasks[port]?.cancel()
        rxTasks[port] = nil
        ports.remove(port)
        periodicTimers[port]?.stop()
      case let .changed(port):
        ports.update(with: port)
      }
      // forward port observation onto applications
      try? await apply(with: portNotification, (any Application<P>).onPortNotification(_:))
    }
  }

  func periodicEnabled() {
    periodicTimers.forEach { $0.value.start(interval: periodicTransmissionTime) }
  }

  func periodicDisabled() {
    periodicTimers.forEach { $0.value.stop() }
  }

  typealias MADApplyFunction = (any Application<P>) async throws -> ()

  @Sendable
  private func apply(_ block: MADApplyFunction) async rethrows {
    for application in applications {
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
    guard applications[application.etherType] == nil
    else { throw MRPError.applicationAlreadyRegistered }
    applications[application.etherType] = application
    try ports.forEach { try $0.addFilter(
      for: application.groupMacAddress,
      etherType: application.etherType
    ) }
  }

  func deregister(application: some Application<P>) throws {
    guard applications[application.etherType] == nil
    else { throw MRPError.applicationNotFound }
    applications.removeValue(forKey: application.etherType)
    for port in ports {
      try? port.removeFilter(
        for: application.groupMacAddress,
        etherType: application.etherType
      )
    }
  }
}
