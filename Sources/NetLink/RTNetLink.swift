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
import CNetLink
import SystemPackage

public struct RTNLLink: NLObjectConstructible, Sendable, CustomStringConvertible {
  private let _object: NLObject

  public init(object: NLObject) throws {
    _object = object
  }

  public var name: String {
    _object.apply {
      String(cString: rtnl_link_get_name($0))
    }
  }

  public var index: Int {
    _object.apply {
      Int(rtnl_link_get_ifindex($0))
    }
  }

  public var description: String {
    name
  }
}

public enum RTNLLinkMessage: NLObjectConstructible, Sendable {
  case new(RTNLLink)
  case del(RTNLLink)

  public init(object: NLObject) throws {
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
  func subscribeRtLinks() async throws -> AnyAsyncSequence<RTNLLinkMessage> {
    let message = try NLMessage(socket: self, type: RTM_GETLINK, flags: NLM_F_REQUEST | NLM_F_DUMP)
    var ifinfo = ifinfomsg()
    try withUnsafeBytes(of: &ifinfo) {
      try message.append(Array($0))
    }
    try message.put(u32: UInt32(IFLA_EXT_MASK), for: RTEXT_FILTER_BRVLAN)
    return try request_N(message: message).map { try RTNLLinkMessage(object: $0) }.eraseToAnyAsyncSequence()
  }
}
