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
import NetLink
import SocketAddress
import SystemPackage

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

func findBridge(named name: String, socket: NLSocket) async throws -> RTNLLinkBridge {
  guard let link = try await socket.getLinks(family: sa_family_t(AF_BRIDGE))
    .first(where: { $0 is RTNLLinkBridge && $0.name == name })
  else {
    print("interface \(name) not found")
    throw Errno.noSuchFileOrDirectory
  }
  return link as! RTNLLinkBridge
}

func findBridge(index: Int, socket: NLSocket) async throws -> RTNLLinkBridge {
  guard let link = try await socket.getLinks(family: sa_family_t(AF_BRIDGE))
    .first(where: { $0 is RTNLLinkBridge && $0.index == index })
  else {
    print("interface \(index) not found")
    throw Errno.noSuchFileOrDirectory
  }
  return link as! RTNLLinkBridge
}

func add_vlan(command: Command, socket: NLSocket, link: RTNLLinkBridge, arg: String) async throws {
  guard let vlan = UInt16(arg) else { usage() }
  try await link.add(vlans: Set([vlan]), socket: socket)
}

func del_vlan(command: Command, socket: NLSocket, link: RTNLLinkBridge, arg: String) async throws {
  guard let vlan = UInt16(arg) else { usage() }
  try await link.remove(vlans: Set([vlan]), socket: socket)
}

func add_group(
  command: Command,
  socket: NLSocket,
  link: RTNLLinkBridge,
  arg: String
) async throws {
  let bridge = try await findBridge(index: link.master, socket: gSocket)
  let groupAddress = try RTNLLink.parseMacAddressString(arg)
  try await bridge.add(link: link, groupAddresses: [groupAddress], socket: socket)
}

func del_group(
  command: Command,
  socket: NLSocket,
  link: RTNLLinkBridge,
  arg: String
) async throws {
  let bridge = try await findBridge(index: link.master, socket: gSocket)
  let groupAddress = try RTNLLink.parseMacAddressString(arg)
  try await bridge.remove(link: link, groupAddresses: [groupAddress], socket: socket)
}

var gSocket: NLSocket!

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

    do {
      let socket = try NLSocket(protocol: NETLINK_ROUTE)
      gSocket = socket
      let link = try await findBridge(named: CommandLine.arguments[2], socket: socket)
      let commands: [Command: CommandHandler] = [
        .add_vlan: add_vlan,
        .del_vlan: del_vlan,
        .add_group: add_group,
        .del_group: del_group,
      ]
      let commandHandler = commands[command]!
      try await commandHandler(command, socket, link, CommandLine.arguments[3])
    } catch {
      print("failed to \(command): \(error)")
      exit(3)
    }
  }
}
