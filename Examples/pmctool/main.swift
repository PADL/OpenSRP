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

import PMC
import SystemPackage

enum Command: CaseIterable {
  case GET_NULL_PTP_MANAGEMENT
  case GET_DEFAULT_DATA_SET
  case GET_PORT_DATA_SET
  case GET_PORT_PROPERTIES_NP
}

typealias CommandHandler = (Command, PTPManagementClient, UInt16) async throws -> ()

func usage() -> Never {
  print(
    "Usage: \(CommandLine.arguments[0]) [GET_NULL_PTP_MANAGEMENT|GET_DEFAULT_DATA_SET|GET_PORT_DATA_SET|GET_PORT_PROPERTIES_NP] [port]"
  )
  exit(1)
}

func GET_NULL_PTP_MANAGEMENT(
  command: Command,
  pmc: PTPManagementClient,
  port: UInt16
) async throws {
  try await pmc.getNullPtpManagement()
}

func GET_DEFAULT_DATA_SET(command: Command, pmc: PTPManagementClient, port: UInt16) async throws {
  let defaultDataSet = try await pmc.getDefaultDataSet()
  print("\(defaultDataSet)")
}

func GET_PORT_DATA_SET(command: Command, pmc: PTPManagementClient, port: UInt16) async throws {
  let portDataSet = try await pmc.getPortDataSet(portNumber: port)
  print("\(portDataSet)")
}

func GET_PORT_PROPERTIES_NP(command: Command, pmc: PTPManagementClient, port: UInt16) async throws {
  let portPropertiesNP = try await pmc.getPortPropertiesNP(portNumber: port)
  print("\(portPropertiesNP)")
}

@main
enum pmctool {
  public static func main() async throws {
    if CommandLine.arguments.count < 2 {
      usage()
    }

    let command = CommandLine.arguments[1]
    guard let command = Command.allCases
      .first(where: { String(describing: $0) == command.uppercased() })
    else {
      usage()
    }

    var port: UInt16?
    if CommandLine.arguments.count > 2 {
      port = UInt16(CommandLine.arguments[2])
    }

    do {
      let commands: [Command: CommandHandler] = [
        .GET_NULL_PTP_MANAGEMENT: GET_NULL_PTP_MANAGEMENT,
        .GET_DEFAULT_DATA_SET: GET_DEFAULT_DATA_SET,
        .GET_PORT_DATA_SET: GET_PORT_DATA_SET,
        .GET_PORT_PROPERTIES_NP: GET_PORT_PROPERTIES_NP,
      ]
      let pmc = try await PTPManagementClient()
      let commandHandler = commands[command]!
      try await commandHandler(
        command,
        pmc,
        port ?? 0
      )
    } catch {
      print("failed to \(command): \(type(of: error)) \(error)")
      exit(3)
    }
  }
}
