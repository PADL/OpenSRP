//
// Copyright (c) 2026 PADL Software Pty Ltd
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

// Query mstpd for a port's CIST spanning-tree role/state via the native control
// client. Usage: mstptool <bridge> <port>

import Logging
import MSTP
#if os(Linux)
import Glibc
#endif

@main
struct MSTPTool {
  static func main() async {
    let logger = Logger(label: "com.padl.mstptool")
    let args = CommandLine.arguments
    guard args.count == 3 else {
      logger.error("usage: \(args.first ?? "mstptool") <bridge> <port>")
      exit(2)
    }
    let bridgeIndex = if_nametoindex(args[1])
    let portIndex = if_nametoindex(args[2])
    guard bridgeIndex != 0, portIndex != 0 else {
      logger.error("unknown interface")
      exit(1)
    }
    guard let client = try? await MSTPControlClient() else {
      logger.error("mstpd not reachable")
      exit(1)
    }
    guard let status = await client.cistPortStatus(
      bridgeIndex: Int32(bitPattern: bridgeIndex),
      portIndex: Int32(bitPattern: portIndex)
    ) else {
      logger.error("no status (mstpd error or port not in this bridge)")
      exit(1)
    }
    logger.info("\(args[2]): role=\(status.role) state=\(status.state)")
  }
}
