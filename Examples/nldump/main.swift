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

@main
enum nldump {
  public static func main() async throws {
    let socket = try NLSocket(protocol: NETLINK_ROUTE)
    for try await link in try await socket.getLinks(family: sa_family_t(AF_BRIDGE)) {
      debugPrint(
        "@\(link.index) found link \(link) MTU \(link.mtu) master \(link.master) slaveOf \(link.slaveOf)"
      )
      if let bridge = link as? RTNLLinkBridge {
        debugPrint(
          " bridge port state \(bridge.bridgePortState) flags \(bridge.bridgeFlags) pvid \(String(describing: bridge.bridgePVID)) hasVLAN \(bridge.bridgeHasVLAN) tagged \(String(describing: bridge.bridgeTaggedVLANs)) untagged \(String(describing: bridge.bridgeUntaggedVLANs))"
        )
      } else if let vlan = link as? RTNLLinkVLAN {
        debugPrint(" vlan ID \(vlan.vlanID ?? 0) flags \(vlan.vlanFlags)")
      }
    }
    for try await addr in try await socket.getAddresses(family: sa_family_t(AF_INET)) {
      debugPrint("@\(addr.index) found address \(addr)")
    }
  }
}
