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
@_spi(SwiftMRPPrivate)
import MRP
import ServiceLifecycle

extension Logger.Level: ExpressibleByArgument {
  public var defaultValueDescription: String {
    String(describing: self)
  }

  public static var allValueStrings: [String] {
    allCases.map { String(describing: $0) }
  }
}

@main
private final class MRPDaemon: AsyncParsableCommand {
  typealias P = LinuxPort
  typealias B = LinuxBridge

  private(set) static var configuration = CommandConfiguration(commandName: "mrpd")

  // TODO: exclude interfaces
  // TODO: do not apply

  @Option(name: .shortAndLong, help: "Master bridge interface name")
  var bridgeInterface: String

  @Option(name: .shortAndLong, help: "NetFilter group")
  var nfGroup: Int = 10

  @Option(name: .shortAndLong, help: "QDisc handle")
  var qDiscHandle: Int = 0x9000

  @Flag(name: .long, help: "Force ports to advertise as AVB capable")
  var forceAvbCapable: Bool = false

  @Flag(name: .long, help: "Enable MSRP talker pruning")
  var enableTalkerPruning: Bool = false

  @Option(name: .long, help: "Maximum number of MSRP fan-in ports")
  var maxFanInPorts: Int = 0

  @Option(name: .long, help: "MSRP SR class A delta bandwidth percentage")
  var classADeltaBandwidth: Int? = nil

  @Option(name: .long, help: "MSRP SR class B delta bandwidth percentage")
  var classBDeltaBandwidth: Int? = nil

  @Option(name: .long, help: "Default MSRP SR PVID")
  var srPVid: UInt16 = SR_PVID.id

  @Option(name: .long, help: "Exclude physical interface (may be specified multiple times)")
  var excludeIface: [String] = []

  @Option(name: .long, help: "Exclude VLAN From MVRP (may be specified multiple times)")
  var excludeVlan: [UInt16] = []

  @Option(name: .shortAndLong, help: "Log level")
  var logLevel: Logger.Level = .debug

  @Flag(name: .long, help: "Enable MMRP")
  var enableMMRP: Bool = false

  @Flag(name: .long, help: "Enable MVRP")
  var enableMVRP: Bool = false

  @Flag(name: .long, help: "Enable MSRP")
  var enableMSRP: Bool = false

  enum CodingKeys: String, CodingKey {
    case bridgeInterface
    case nfGroup
    case qDiscHandle
    case forceAvbCapable
    case enableTalkerPruning
    case maxFanInPorts
    case srPVid
    case classADeltaBandwidth
    case classBDeltaBandwidth
    case excludeIface
    case excludeVlan
    case logLevel
    case enableMMRP
    case enableMVRP
    case enableMSRP
  }

  var logger: Logger!

  func run() async throws {
    LoggingSystem.bootstrap { @Sendable in
      StreamLogHandler.standardError(label: $0)
    }
    logger = Logger(label: "com.padl.mrpd")
    logger.logLevel = logLevel

    let bridge = try B(name: bridgeInterface, netFilterGroup: nfGroup, qDiscHandle: qDiscHandle)
    let controller = try await MRPController<P>(
      bridge: bridge,
      logger: logger,
      portExclusions: Set(excludeIface)
    )
    if enableMMRP {
      _ = try await MMRPApplication(controller: controller)
    }
    if enableMVRP {
      _ = try await MVRPApplication(
        controller: controller,
        vlanExclusions: Set(excludeVlan.map { VLAN(id: $0) })
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
      _ = try await MSRPApplication(
        controller: controller,
        talkerPruning: enableTalkerPruning,
        maxFanInPorts: maxFanInPorts,
        srPVid: VLAN(id: srPVid),
        deltaBandwidths: deltaBandwidths,
        forceAvbCapable: forceAvbCapable
      )
    }

    let serviceGroup = ServiceGroup(
      services: [controller],
      gracefulShutdownSignals: [.sigterm, .sigint],
      logger: logger
    )
    try await serviceGroup.run()
  }
}
