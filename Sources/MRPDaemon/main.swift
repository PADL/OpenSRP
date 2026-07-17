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

import ArgumentParser
import Logging
import MRP
import ServiceLifecycle
import Systemd
import SystemdLifecycle

extension Duration: @retroactive ExpressibleByArgument {
  public var defaultValueDescription: String {
    String(describing: self)
  }

  public init?(argument: String) {
    guard let argument = Double(argument) else { return nil }
    self = .seconds(argument)
  }
}

extension Logger.Level: @retroactive ExpressibleByArgument {
  public var defaultValueDescription: String {
    String(describing: self)
  }

  public static var allValueStrings: [String] {
    allCases.map { String(describing: $0) }
  }
}

extension MSRPFilteringType: ExpressibleByArgument {}

extension TimeSyncBackend: ExpressibleByArgument {}

@main
private final class MRPDaemon: AsyncParsableCommand {
  typealias P = LinuxPort
  typealias B = LinuxBridge

  static let configuration = CommandConfiguration(commandName: "mrpd")

  // TODO: exclude interfaces
  // TODO: do not apply

  @Option(name: .shortAndLong, help: "Master bridge interface name")
  var bridgeInterface: String

  @Option(name: .shortAndLong, help: "Qdisc handle")
  var qDiscHandle: UInt16 = 0x9000

  @Flag(name: .long, help: "Force ports to advertise as AVB capable")
  var forceAvbCapable: Bool = false

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Ignore gPTP asCapable, do not query PTP (--no-ignore-as-capable enforces 35.2.1)"
  )
  var ignoreAsCapable: Bool = true

  @Flag(name: .long, help: "Enable MSRP talker pruning")
  var enableTalkerPruning: Bool = false

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "MSRP immediate Registrar leave on received Leave (Avnu §9.2)"
  )
  var leaveImmediate: Bool = true

  @Option(name: .long, help: "Maximum number of MSRP fan-in ports")
  var maxFanInPorts: Int = 0

  @Option(name: .long, help: "Global MSRP Talker attribute limit (0 disables the limit)")
  var maxTalkerAttributes: Int = 150

  @Option(name: .long, help: "MSRP SR class A Qdisc handle (queue)")
  var classAQdiscHandle: UInt = 4

  @Option(name: .long, help: "MSRP SR class B Qdsisc handle (queue)")
  var classBQdiscHandle: UInt = 3

  @Option(name: .long, help: "MSRP SR class A delta bandwidth percentage")
  var classADeltaBandwidth: Int? = nil

  @Option(name: .long, help: "MSRP SR class B delta bandwidth percentage")
  var classBDeltaBandwidth: Int? = nil

  @Flag(name: .long, help: "Automatically configure MQPRIO egress queues")
  var configureEgressQueues: Bool = false

  @Flag(name: .long, help: "Automatically configure DCBNL ingress queue (PCP) mapping")
  var configureIngressQueues: Bool = false

  @Flag(name: .long, help: "Automatically configure both ingress and egress queues")
  var configureQueues: Bool = false

  @Flag(name: .long, help: "Install an MDB entry on the Talker's ingress port (secure switch mode)")
  var configureIngressMdb: Bool = false

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Install an nftables drop for MMRP/MVRP frames so the bridge does not flood them"
  )
  var configureNftDrop: Bool = true

  @Option(
    name: .long,
    help: "Per-port AVB admission-control mechanism (\(MSRPFilteringType.allCases.map(\.rawValue).joined(separator: ", ")))"
  )
  var configureFiltering: MSRPFilteringType? = nil

  @Option(name: .long, help: "MSRP SR PVID (the VLAN both SR classes declare, 35.2.1.4)")
  var srPVid: UInt16 = SR_PVID.id

  @Option(name: .long, help: "Exclude physical interface (may be specified multiple times)")
  var excludeIface: [String] = []

  @Option(name: .long, help: "Exclude VLAN From MVRP (may be specified multiple times)")
  var excludeVlan: [UInt16] = []

  @Option(name: .shortAndLong, help: "Log level")
  var logLevel: Logger.Level = .info

  @Flag(name: .long, help: "Enable MMRP")
  var enableMMRP: Bool = false

  @Flag(name: .long, help: "Enable MVRP")
  var enableMVRP: Bool = false

  @Flag(
    name: .long,
    inversion: .prefixedNo,
    help: "Declare each port's PVID over MVRP (11.2.1.3)"
  )
  var declarePVID: Bool = false

  @Flag(name: .long, help: "Enable MSRP")
  var enableMSRP: Bool = false

  @Flag(name: .long, help: .hidden)
  var enableSRP: Bool = false

  @Flag(name: .long, help: .hidden)
  var forceFullParticipant: Bool = false

  @Option(name: .long, help: "gPTP daemon to query for asCapable and peer delay")
  var timeSync: TimeSyncBackend = .ptp4l

  @Option(name: .long, help: "gPTP daemon domain socket path (default: the backend's own)")
  var timeSyncPath: String? = nil

  @Option(name: .long, help: "MRP Join time interval")
  var joinTime: Duration = JoinTime

  @Option(name: .long, help: "MRP Leave time interval")
  var leaveTime: Duration = LeaveTime

  @Option(name: .long, help: "MRP LeaveAll time interval")
  var leaveAllTime: Duration = LeaveAllTime

  // enabled by default: required for robust interop with short-LeaveTime peers (10.7.2)
  @Option(name: .long, help: "MRP Periodic TX time interval (0 = disabled)")
  var periodicTime: Duration = .seconds(1)

  #if RestAPI
  @Option(name: .shortAndLong, help: "REST HTTP server port")
  var restServerPort: UInt16?
  #endif

  enum CodingKeys: String, CodingKey {
    case bridgeInterface
    case qDiscHandle
    case forceAvbCapable
    case ignoreAsCapable
    case enableTalkerPruning
    case leaveImmediate
    case maxFanInPorts
    case maxTalkerAttributes
    case classADeltaBandwidth
    case classBDeltaBandwidth
    case classAQdiscHandle
    case classBQdiscHandle
    case configureEgressQueues
    case configureIngressQueues
    case configureQueues
    case configureIngressMdb
    case configureNftDrop
    case configureFiltering
    case excludeIface
    case excludeVlan
    case srPVid
    case logLevel
    case enableMMRP
    case enableMVRP
    case declarePVID
    case enableMSRP
    case enableSRP
    case forceFullParticipant
    case timeSync
    case timeSyncPath
    case joinTime
    case leaveTime
    case leaveAllTime
    case periodicTime
    #if RestAPI
    case restServerPort
    #endif
  }

  var logger: Logger!

  func run() async throws {
    if SystemdHelpers.isSystemdService {
      LoggingSystem.bootstrap(SystemdJournalLogHandler.init)
    } else {
      LoggingSystem.bootstrap { @Sendable in
        StreamLogHandler.standardError(label: $0)
      }
    }
    logger = Logger(label: "com.padl.mrpd")
    logger.logLevel = logLevel

    let timerConfiguration = MRPTimerConfiguration(
      joinTime: joinTime,
      leaveTime: leaveTime,
      leaveAllTime: leaveAllTime,
      periodicTime: periodicTime
    )

    let bridge = try await B(
      name: bridgeInterface,
      qDiscHandle: qDiscHandle,
      timeSyncBackend: timeSync,
      timeSyncSocketPath: timeSyncPath,
      portExclusions: Set(excludeIface),
      logger: logger
    )
    #if !RestAPI
    let restServerPort: UInt16? = nil
    #endif

    var mrpFlags: MRPFlags = []
    if forceFullParticipant { mrpFlags.insert(.forceFullParticipant) }
    if configureNftDrop { mrpFlags.insert(.configureFrameFiltering) }

    let controller = try await MRPController<P>(
      bridge: bridge,
      logger: logger,
      timerConfiguration: timerConfiguration,
      portExclusions: Set(excludeIface),
      restServerPort: restServerPort,
      flags: mrpFlags
    )
    if enableSRP {
      enableMMRP = false
      enableMVRP = true
      enableMSRP = true
    }
    if enableMMRP {
      _ = try await MMRPApplication(controller: controller)
    }
    // both SR classes declare the single SR_PVID (35.2.1.4)
    let srPVidVLAN = VLAN(id: srPVid)

    if enableMVRP {
      _ = try await MVRPApplication(
        controller: controller,
        vlanExclusions: Set(excludeVlan.map { VLAN(id: $0) }),
        declarePVID: declarePVID
      )
    }
    if enableMSRP {
      var deltaBandwidths = [SRclassID: Int]()
      if let classADeltaBandwidth {
        deltaBandwidths[.A] = classADeltaBandwidth
      }
      if let classBDeltaBandwidth {
        deltaBandwidths[.B] = classBDeltaBandwidth
      }
      let queues: [SRclassID: UInt] = [.A: classAQdiscHandle, .B: classBQdiscHandle]
      var flags: MSRPApplicationFlags = .defaultFlags
      if enableTalkerPruning { flags.insert(.talkerPruning) }
      if !leaveImmediate { flags.remove(.leaveImmediate) }
      if forceAvbCapable { flags.insert(.forceAvbCapable) }
      if ignoreAsCapable { flags.insert(.ignoreAsCapable) }
      if configureEgressQueues || configureQueues { flags.insert(.configureEgressQueues) }
      if configureIngressQueues || configureQueues { flags.insert(.configureIngressQueues) }
      if configureIngressMdb { flags.insert(.configureIngressMdb) }

      _ = try await MSRPApplication(
        controller: controller,
        flags: flags,
        maxFanInPorts: maxFanInPorts,
        srPVid: srPVidVLAN,
        queues: queues,
        deltaBandwidths: deltaBandwidths.isEmpty ? nil : deltaBandwidths,
        maxTalkerAttributes: maxTalkerAttributes,
        filtering: configureFiltering
      )
    }

    var services: [Service] = [controller]

    #if os(Linux)
    if SystemdHelpers.isSystemdService {
      services.append(SystemdService())
    }
    #endif

    let serviceGroup = ServiceGroup(
      services: services,
      gracefulShutdownSignals: [.sigterm, .sigint],
      logger: logger
    )
    try await serviceGroup.run()
  }
}
