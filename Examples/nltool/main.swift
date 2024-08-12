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

import CLinuxSockAddr
import CNetLink
import Dispatch
import IORing
import IORingUtils
import NetLink
import SocketAddress

enum Command: CaseIterable {
  case add_vlan
  case del_vlan
  case add_group
  case del_group
}

typealias CommandHandler = (Command, NLSocket, RTNLLinkBridge, String) async throws -> ()

func usage() -> Never {
  print("Usage: \(CommandLine.arguments[0]) [add_vlan|del_vlan|add_group|del_group] [ifname] [vid]")
  exit(1)
}

func add_vlan(command: Command, socket: NLSocket, link: RTNLLinkBridge, arg: String) async throws {
  guard let vlan = UInt16(arg) else { usage() }
  try await link.add(vlans: Set([vlan]), socket: socket)
}

func del_vlan(command: Command, socket: NLSocket, link: RTNLLinkBridge, arg: String) async throws {
  guard let vlan = UInt16(arg) else { usage() }
  try await link.remove(vlans: Set([vlan]), socket: socket)
}

func _addOrDelMulti(groupAddress: String, index: Int, isAdd: Bool) async throws {
  var groupAddress = try sockaddr_ll(
    family: sa_family_t(AF_PACKET),
    presentationAddress: groupAddress
  )

  groupAddress.sll_ifindex = CInt(index)

  let socket = try Socket(
    ring: IORing.shared,
    domain: sa_family_t(AF_PACKET),
    type: SOCK_RAW
  )
  if isAdd {
    try socket.addMulticastMembership(for: groupAddress)
  } else {
    try socket.dropMulticastMembership(for: groupAddress)
  }
}

func add_group(
  command: Command,
  socket: NLSocket,
  link: RTNLLinkBridge,
  arg: String
) async throws {
  try await _addOrDelMulti(groupAddress: arg, index: link.index, isAdd: true)
}

func del_group(
  command: Command,
  socket: NLSocket,
  link: RTNLLinkBridge,
  arg: String
) async throws {
  try await _addOrDelMulti(groupAddress: arg, index: link.index, isAdd: false)
}

@main
enum nltool {
  public static func main() async throws {
    if CommandLine.arguments.count < 4 {
      usage()
    }

    guard let command = Command.allCases
      .first(where: { String(describing: $0) == CommandLine.arguments[1] })
    else {
      usage()
    }

    let socket = try NLSocket(protocol: NETLINK_ROUTE)

    guard let link = try await socket.getLinks(family: sa_family_t(AF_BRIDGE))
      .first(where: { $0.name == CommandLine.arguments[2] })
    else {
      print("interface \(CommandLine.arguments[2]) not found")
      exit(2)
    }

    do {
      let commands: [Command: CommandHandler] = [
        .add_vlan: add_vlan,
        .del_vlan: del_vlan,
        .add_group: add_group,
        .del_group: del_group,
      ]
      let commandHandler = commands[command]!
      try await commandHandler(command, socket, link as! RTNLLinkBridge, CommandLine.arguments[3])
    } catch {
      print("failed to \(command): \(error)")
      exit(3)
    }
    try await Task.sleep(for: .seconds(10))
  }
}
