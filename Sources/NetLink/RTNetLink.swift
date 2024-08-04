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

import AsyncAlgorithms
import AsyncExtensions
import CLinuxSockAddr
import CNetLink
import SystemPackage

public struct RTNLLink: NLObjectConstructible, Sendable, CustomStringConvertible {
  private let _object: NLObject

  init(object: NLObject) throws {
    _object = object
  }

  private var _obj: OpaquePointer {
    _object._obj
  }

  public var name: String {
    String(cString: rtnl_link_get_name(_obj))
  }

  public var master: Int {
    Int(rtnl_link_get_master(_obj))
  }

  public var index: Int {
    Int(rtnl_link_get_ifindex(_obj))
  }

  public var mtu: Int {
    Int(rtnl_link_get_mtu(_obj))
  }

  public var description: String {
    "\(index):\(name):\(family):\(addressString):\(String(format: "%08x", flags))"
  }

  public var flags: Int {
    Int(rtnl_link_get_flags(_obj))
  }

  public var addressString: String {
    let address = address
    return String(
      format: "%02x:%02x:%02x:%02x:%02x:%02x",
      address.0,
      address.1,
      address.2,
      address.3,
      address.4,
      address.5
    )
  }

  private func _makeAddress(_ addr: OpaquePointer)
    -> (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
  {
    var mac = [UInt8](repeating: 0, count: Int(nl_addr_get_len(addr)))
    precondition(mac.count == Int(ETH_ALEN))
    _ = mac.withUnsafeMutableBytes {
      memcpy($0.baseAddress!, nl_addr_get_binary_addr(addr), Int(nl_addr_get_len(addr)))
    }
    return (mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
  }

  public var address: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) {
    _makeAddress(rtnl_link_get_addr(_obj))
  }

  public var broadcastAddress: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) {
    _makeAddress(rtnl_link_get_broadcast(_obj))
  }

  public var family: Int {
    Int(rtnl_link_get_family(_obj))
  }
}

public enum RTNLLinkMessage: NLObjectConstructible, Sendable {
  case new(RTNLLink)
  case del(RTNLLink)

  init(object: NLObject) throws {
    switch object.messageType {
    case RTM_NEWLINK:
      self = try .new(RTNLLink(object: object))
    case RTM_DELLINK:
      self = try .del(RTNLLink(object: object))
    default:
      throw Errno.invalidArgument
    }
  }
}

public extension NLSocket {
  func getRtLinks() async throws -> AnyAsyncSequence<RTNLLinkMessage> {
    let message = try NLMessage(socket: self, type: RTM_GETLINK, flags: NLM_F_REQUEST | NLM_F_DUMP)
    var ifinfo = ifinfomsg()
    try withUnsafeBytes(of: &ifinfo) {
      try message.append(Array($0))
    }
    try message.put(u32: UInt32(IFLA_EXT_MASK), for: RTEXT_FILTER_BRVLAN)
    return try streamRequest(message: message).map { $0 as! RTNLLinkMessage }
      .eraseToAnyAsyncSequence()
  }

  func notifyRtLinks() throws {
    try add(membership: RTNLGRP_LINK)
  }
}
