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

  @Option(name: .long, help: "Exclude physical interface (may be specified multiple times)")
  var excludeIface: [String] = []

  @Option(name: .long, help: "Exclude VLAN From MVRP (may be specified multiple times)")
  var excludeVlan: [UInt16] = []

  @Option(name: .shortAndLong, help: "Log level")
  var logLevel: Logger.Level = .trace

  @Flag(name: .long, help: "Enable MMRP")
  var enableMMRP: Bool = false

  @Flag(name: .long, help: "Enable MVRP")
  var enableMVRP: Bool = false

  @Flag(name: .long, help: "Enable MSRP")
  var enableMSRP: Bool = false

  enum CodingKeys: String, CodingKey {
    case bridgeInterface
    case nfGroup
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

    let bridge = try await B(name: bridgeInterface, netFilterGroup: nfGroup)
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
    if enableMSRP {}

    let serviceGroup = ServiceGroup(
      services: [controller],
      gracefulShutdownSignals: [.sigterm, .sigint],
      logger: logger
    )
    try await serviceGroup.run()
  }
}
