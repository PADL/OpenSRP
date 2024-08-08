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

extension [UInt8] {
  struct HexEncodingOptions: OptionSet {
    let rawValue: Int
    static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
  }

  func hexEncodedString(options: HexEncodingOptions = []) -> String {
    let hexDigits = options.contains(.upperCase) ? "0123456789ABCDEF" : "0123456789abcdef"
    let utf8Digits = Array(hexDigits.utf8)
    return String(unsafeUninitializedCapacity: 2 * count) { ptr -> Int in
      var p = ptr.baseAddress!
      for byte in self {
        p[0] = utf8Digits[Int(byte / 16)]
        p[1] = utf8Digits[Int(byte % 16)]
        p += 2
      }
      return 2 * self.count
    }
  }
}

@main
private final class MRPDaemon: AsyncParsableCommand {
  typealias P = LinuxPort
  typealias B = LinuxBridge

  private(set) static var configuration = CommandConfiguration(commandName: "mrpd")

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
    case enableMMRP
    case enableMVRP
    case enableMSRP
  }

  var logger: Logger!

  func run() async throws {
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    logger = Logger(label: "com.lukktone.mrpd")
    logger.logLevel = logLevel

    let serviceGroup = ServiceGroup(
      services: [],
      gracefulShutdownSignals: [.sigterm, .sigint],
      logger: logger
    )
    try await serviceGroup.run()
  }
}
