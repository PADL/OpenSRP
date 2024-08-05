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

import CNetLink
import Dispatch
import NetLink
@_spi(MRPPrivate)
import MRP

@main
struct portmon {
  public static func main() async throws {
    let bridge = try await LinuxBridge(name: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "br0")
    print("Ports at startup on bridge \(bridge.name):")
    for port in try await bridge.ports {
      print("\(port)")
    }
    print("Now monitoring for changes...")
    for try await notification in bridge.notifications {
      print("\(notification)")
    }
  }
}
