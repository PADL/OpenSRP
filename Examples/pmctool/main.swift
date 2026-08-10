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

import Glibc
import PMC
import SystemPackage

enum Command: String, CaseIterable {
  case GET_NULL_PTP_MANAGEMENT
  case GET_CLOCK_DESCRIPTION
  case GET_USER_DESCRIPTION
  case GET_DEFAULT_DATA_SET
  case GET_CURRENT_DATA_SET
  case GET_PARENT_DATA_SET
  case GET_TIME_PROPERTIES_DATA_SET
  case GET_PRIORITY1
  case GET_PRIORITY2
  case GET_DOMAIN
  case GET_SLAVE_ONLY
  case GET_CLOCK_ACCURACY
  case GET_TRACEABILITY_PROPERTIES
  case GET_TIMESCALE_PROPERTIES
  case GET_PORT_DATA_SET
  case GET_LOG_ANNOUNCE_INTERVAL
  case GET_ANNOUNCE_RECEIPT_TIMEOUT
  case GET_LOG_SYNC_INTERVAL
  case GET_VERSION_NUMBER
  case GET_MASTER_ONLY
  case GET_DELAY_MECHANISM
  case GET_LOG_MIN_PDELAY_REQ_INTERVAL
  case GET_TIME_STATUS_NP
  case GET_GRANDMASTER_SETTINGS_NP
  case GET_SUBSCRIBE_EVENTS_NP
  case GET_SYNCHRONIZATION_UNCERTAIN_NP
  case GET_EXTERNAL_GRANDMASTER_PROPERTIES_NP
  case GET_PORT_DATA_SET_NP
  case GET_PORT_PROPERTIES_NP
  case GET_PORT_STATS_NP
  case GET_PORT_SERVICE_STATS_NP
  case GET_UNICAST_MASTER_TABLE_NP
  case GET_PORT_HWCLOCK_NP
  case GET_POWER_PROFILE_SETTINGS_NP
  case GET_CMLDS_INFO_NP
  case GET_PORT_CORRECTIONS_NP
  case ENABLE_PORT
  case DISABLE_PORT
}

func usage() -> Never {
  print("Usage: \(CommandLine.arguments[0]) <command> [port]")
  print("Commands:")
  for command in Command.allCases {
    print("  \(command.rawValue)")
  }
  exit(1)
}

func run(_ command: Command, _ pmc: PTPManagementClient, _ portArg: UInt16?) async throws {
  // commands addressed to a port rather than to the clock require the port argument
  func port() -> UInt16 {
    guard let portArg else { usage() }
    return portArg
  }

  switch command {
  case .GET_NULL_PTP_MANAGEMENT: try await pmc.getNullPtpManagement()
  case .GET_CLOCK_DESCRIPTION: try await print(pmc.getClockDescription(portNumber: port()))
  case .GET_USER_DESCRIPTION: try await print(pmc.getUserDescription())
  case .GET_DEFAULT_DATA_SET: try await print(pmc.getDefaultDataSet())
  case .GET_CURRENT_DATA_SET: try await print(pmc.getCurrentDataSet())
  case .GET_PARENT_DATA_SET: try await print(pmc.getParentDataSet())
  case .GET_TIME_PROPERTIES_DATA_SET: try await print(pmc.getTimePropertiesDataSet())
  case .GET_PRIORITY1: try await print(pmc.getPriority1())
  case .GET_PRIORITY2: try await print(pmc.getPriority2())
  case .GET_DOMAIN: try await print(pmc.getDomain())
  case .GET_SLAVE_ONLY: try await print(pmc.getSlaveOnly())
  case .GET_CLOCK_ACCURACY: try await print(pmc.getClockAccuracy())
  case .GET_TRACEABILITY_PROPERTIES: try await print(pmc.getTraceabilityProperties())
  case .GET_TIMESCALE_PROPERTIES: try await print(pmc.getTimescaleProperties())
  case .GET_PORT_DATA_SET: try await print(pmc.getPortDataSet(portNumber: port()))
  case .GET_LOG_ANNOUNCE_INTERVAL: try await print(pmc.getLogAnnounceInterval(portNumber: port()))
  case .GET_ANNOUNCE_RECEIPT_TIMEOUT:
    try await print(pmc.getAnnounceReceiptTimeout(portNumber: port()))
  case .GET_LOG_SYNC_INTERVAL: try await print(pmc.getLogSyncInterval(portNumber: port()))
  case .GET_VERSION_NUMBER: try await print(pmc.getVersionNumber(portNumber: port()))
  case .GET_MASTER_ONLY: try await print(pmc.getMasterOnly(portNumber: port()))
  case .GET_DELAY_MECHANISM: try await print(pmc.getDelayMechanism(portNumber: port()))
  case .GET_LOG_MIN_PDELAY_REQ_INTERVAL:
    try await print(pmc.getLogMinPdelayReqInterval(portNumber: port()))
  case .GET_TIME_STATUS_NP: try await print(pmc.getTimeStatusNP())
  case .GET_GRANDMASTER_SETTINGS_NP: try await print(pmc.getGrandmasterSettingsNP())
  case .GET_SUBSCRIBE_EVENTS_NP: try await print(pmc.getSubscribeEventsNP())
  case .GET_SYNCHRONIZATION_UNCERTAIN_NP: try await print(pmc.getSynchronizationUncertainNP())
  case .GET_EXTERNAL_GRANDMASTER_PROPERTIES_NP:
    try await print(pmc.getExternalGrandmasterPropertiesNP())
  case .GET_PORT_DATA_SET_NP: try await print(pmc.getPortDataSetNP(portNumber: port()))
  case .GET_PORT_PROPERTIES_NP: try await print(pmc.getPortPropertiesNP(portNumber: port()))
  case .GET_PORT_STATS_NP: try await print(pmc.getPortStatsNP(portNumber: port()))
  case .GET_PORT_SERVICE_STATS_NP: try await print(pmc.getPortServiceStatsNP(portNumber: port()))
  case .GET_UNICAST_MASTER_TABLE_NP: try await print(pmc
      .getUnicastMasterTableNP(portNumber: port()))
  case .GET_PORT_HWCLOCK_NP: try await print(pmc.getPortHwclockNP(portNumber: port()))
  case .GET_POWER_PROFILE_SETTINGS_NP:
    try await print(pmc.getPowerProfileSettingsNP(portNumber: port()))
  case .GET_CMLDS_INFO_NP: try await print(pmc.getCmldsInfoNP(portNumber: port()))
  case .GET_PORT_CORRECTIONS_NP: try await print(pmc.getPortCorrectionsNP(portNumber: port()))
  case .ENABLE_PORT: try await pmc.enablePort(portNumber: port())
  case .DISABLE_PORT: try await pmc.disablePort(portNumber: port())
  }
}

@main
enum pmctool {
  static func main() async throws {
    if CommandLine.arguments.count < 2 {
      usage()
    }

    guard let command = Command(rawValue: CommandLine.arguments[1].uppercased()) else {
      usage()
    }

    var port: UInt16?
    if CommandLine.arguments.count > 2 {
      port = UInt16(CommandLine.arguments[2])
    }

    do {
      let pmc = try await PTPManagementClient()
      try await run(command, pmc, port)
    } catch {
      print("failed to \(command): \(type(of: error)) \(error)")
      exit(3)
    }
  }
}
