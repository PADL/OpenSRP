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

public struct NFNLLogMessage: NLObjectConstructible, Sendable {
  private let _object: NLObject

  public init(object: NLObject) throws {
    _object = object
  }

  fileprivate var _obj: OpaquePointer {
    _object._obj
  }

  public var family: sa_family_t {
    sa_family_t(nfnl_log_msg_get_family(_obj))
  }

  public var hwProtocol: UInt16? {
    guard nfnl_log_msg_test_hwproto(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_hwproto(_obj)
  }

  public var hook: UInt8? {
    guard nfnl_log_msg_test_hook(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_hook(_obj)
  }

  public var mark: UInt32? {
    guard nfnl_log_msg_test_mark(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_mark(_obj)
  }

  public var timestamp: timeval? {
    guard let ts = nfnl_log_msg_get_timestamp(_obj) else { return nil }
    return ts.pointee
  }

  public var inputDevice: Int {
    Int(nfnl_log_msg_get_indev(_obj))
  }

  public var outputDevice: Int {
    Int(nfnl_log_msg_get_outdev(_obj))
  }

  public var physicalInputDevice: Int {
    Int(nfnl_log_msg_get_physindev(_obj))
  }

  public var physicalOutputDevice: Int {
    Int(nfnl_log_msg_get_physoutdev(_obj))
  }

  public var vlanProtocol: UInt16? {
    guard nfnl_log_msg_test_vlan_proto(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_vlan_proto(_obj)
  }

  public var vlanTag: UInt16? {
    guard nfnl_log_msg_test_vlan_tag(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_vlan_tag(_obj)
  }

  public var vlanID: UInt16? {
    guard nfnl_log_msg_test_vlan_tag(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_vlan_id(_obj)
  }

  public var vlanCFI: UInt16? {
    guard nfnl_log_msg_test_vlan_tag(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_vlan_cfi(_obj)
  }

  public var vlanPriority: UInt16? {
    guard nfnl_log_msg_test_vlan_tag(_obj) != 0 else { return nil }
    return nfnl_log_msg_get_vlan_cfi(_obj)
  }

  public var hwAddress: [UInt8]? {
    var length: CInt = 0
    guard let hwAddress = nfnl_log_msg_get_hwaddr(_obj, &length) else { return nil }
    return Array(UnsafeBufferPointer(start: hwAddress, count: Int(length)))
  }

  public var macAddress: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)? {
    guard let hwAddress, hwAddress.count == 6 else { return nil }
    return (hwAddress[0], hwAddress[1], hwAddress[2], hwAddress[3], hwAddress[4], hwAddress[5])
  }

  public var payload: [UInt8]? {
    var length: CInt = 0
    guard let payload = nfnl_log_msg_get_payload(_obj, &length) else { return nil }
    return payload.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { payload in
      Array(UnsafeBufferPointer(start: payload, count: Int(length)))
    }
  }

  public var prefix: String? {
    guard let prefix = nfnl_log_msg_get_prefix(_obj) else { return nil }
    return String(cString: prefix)
  }
}

public final class NFNLLog: Sendable {
  private let _socket: NLSocket
  private let _log: NLObject

  public init(family: sa_family_t = sa_family_t(AF_PACKET), group: UInt16) throws {
    _socket = try NLSocket(protocol: NETLINK_NETFILTER)
    _log = NLObject(consumingObj: nfnl_log_alloc())
    try throwingErrno {
      nfnl_log_pf_bind(_socket._sk, UInt8(family))
    }
    nfnl_log_set_group(_log._obj, group)
    nfnl_log_set_copy_mode(_log._obj, NFNL_LOG_COPY_PACKET)
    nfnl_log_set_copy_range(_log._obj, 0xFFFF)
    try throwingErrno {
      nfnl_log_create(_socket._sk, _log._obj)
    }
  }

  public var logMessages: AnyAsyncSequence<NFNLLogMessage> {
    _socket.notifications.map { $0 as! NFNLLogMessage }.eraseToAnyAsyncSequence()
  }
}
