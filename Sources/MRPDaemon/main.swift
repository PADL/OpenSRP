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
  var nfGroup: Int = 100

  @Option(name: .shortAndLong, help: "Physical interfaces to exclude")
  var excludeIface: [String]?

  @Option(name: .shortAndLong, help: "Log level")
  var logLevel: Logger.Level = .trace

  @Flag(name: .long, help: "Enable MMRP")
  var enableMMRP: Bool = false

  @Flag(name: .long, help: "Enable MVRP")
  var enableMVRP: Bool = false

  @Flag(name: .long, help: "Enable MSRP")
  var enableMSRP: Bool = false

  enum CodingKeys: String, CodingKey {
    case logLevel
    case excludeIface
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
    let mad = try await MAD<P>(bridge: bridge, logger: logger)
    if enableMMRP {
      _ = try await MMRPApplication(owner: mad)
    }
    if enableMVRP {
      _ = try await MVRPApplication(owner: mad)
    }
    if enableMSRP {}

    let serviceGroup = ServiceGroup(
      services: [mad],
      gracefulShutdownSignals: [.sigterm, .sigint],
      logger: logger
    )
    try await serviceGroup.run()
  }
}
