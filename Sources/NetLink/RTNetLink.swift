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

protocol RTNLLinkFactory {}

extension RTNLLinkFactory {
  init(reassigningSelfTo other: Self) {
    self = other
  }
}

public class RTNLLink: NLObjectConstructible, @unchecked Sendable, CustomStringConvertible,
  RTNLLinkFactory
{
  private let _object: NLObject

  fileprivate init(_ object: NLObject) {
    _object = object
  }

  convenience init(object: NLObject) {
    if rtnl_link_is_bridge(object._obj) != 0 {
      self.init(reassigningSelfTo: RTNLLinkBridge(object) as! Self)
    } else if rtnl_link_is_vlan(object._obj) != 0 {
      self.init(reassigningSelfTo: RTNLLinkVLAN(object) as! Self)
    } else {
      self.init(object)
    }
  }

  fileprivate var _obj: OpaquePointer {
    _object._obj
  }

  public var name: String {
    String(cString: rtnl_link_get_name(_obj))
  }

  public var index: Int {
    Int(rtnl_link_get_ifindex(_obj))
  }

  public var mtu: Int {
    Int(rtnl_link_get_mtu(_obj))
  }

  public var description: String {
    "\(Swift.type(of: self))(\(index):\(name):\(family):\(addressString):\(String(format: "%08x", flags)))"
  }

  public var flags: Int {
    Int(rtnl_link_get_flags(_obj))
  }

  public var group: UInt32 {
    rtnl_link_get_group(_obj)
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

  public typealias Address = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

  private func _makeAddress(_ addr: OpaquePointer) -> Address {
    var mac = [UInt8](repeating: 0, count: Int(nl_addr_get_len(addr)))
    precondition(mac.count == Int(ETH_ALEN))
    _ = mac.withUnsafeMutableBytes {
      memcpy($0.baseAddress!, nl_addr_get_binary_addr(addr), Int(nl_addr_get_len(addr)))
    }
    return (mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
  }

  public var address: Address {
    _makeAddress(rtnl_link_get_addr(_obj))
  }

  public var broadcastAddress: Address {
    _makeAddress(rtnl_link_get_broadcast(_obj))
  }

  public var family: sa_family_t {
    sa_family_t(rtnl_link_get_family(_obj))
  }

  public var arpType: UInt16 {
    UInt16(rtnl_link_get_arptype(_obj))
  }

  public var txQLen: Int {
    Int(rtnl_link_get_txqlen(_obj))
  }

  public var master: Int {
    Int(rtnl_link_get_master(_obj))
  }

  public var slaveOf: Int {
    Int(rtnl_link_get_link(_obj))
  }

  public var carrier: UInt8 {
    rtnl_link_get_carrier(_obj)
  }

  // IF_OPER_XXX
  public var operationalState: UInt8 {
    rtnl_link_get_operstate(_obj)
  }

  // LINK_MODE_XXX
  public var linkMode: UInt8 {
    rtnl_link_get_linkmode(_obj)
  }

  public var aliasName: String? {
    if let alias = rtnl_link_get_ifalias(_obj) {
      String(cString: alias)
    } else {
      nil
    }
  }

  public var qDisc: String? {
    if let qdisc = rtnl_link_get_qdisc(_obj) {
      String(cString: qdisc)
    } else {
      nil
    }
  }

  public var numVF: Int {
    get throws {
      var numVF = UInt32(0)
      let r = rtnl_link_get_num_vf(_obj, &numVF)
      if r < 0 {
        throw Errno(rawValue: -r)
      }
      return Int(numVF)
    }
  }

  public func getStatistics(id: rtnl_link_stat_id_t) -> UInt64 {
    rtnl_link_get_stat(_obj, id)
  }

  public var type: String? {
    if let type = rtnl_link_get_type(_obj) {
      String(cString: type)
    } else {
      nil
    }
  }

  public var slaveType: String? {
    if let type = rtnl_link_get_slave_type(_obj) {
      String(cString: type)
    } else {
      nil
    }
  }

  public var promiscuity: UInt32 {
    rtnl_link_get_promiscuity(_obj)
  }

  public var numTXQueues: UInt32 {
    rtnl_link_get_num_tx_queues(_obj)
  }

  public var numRXQueues: UInt32 {
    rtnl_link_get_num_rx_queues(_obj)
  }

  public var physicalPortName: String? {
    if let name = rtnl_link_get_phys_port_name(_obj) {
      String(cString: name)
    } else {
      nil
    }
  }

  public var physicalPortID: NLData? {
    NLData(data: rtnl_link_get_phys_port_id(_obj))
  }

  public var physicalSwitchID: NLData? {
    NLData(data: rtnl_link_get_phys_switch_id(_obj))
  }
}

public final class RTNLLinkBridge: RTNLLink {
  var bridgeHasExtendedInfo: Bool {
    rtnl_link_bridge_has_ext_info(_obj) != 0
  }

  public var bridgePortState: UInt8 {
    UInt8(rtnl_link_bridge_get_port_state(_obj))
  }

  public var bridgePriority: UInt16 {
    UInt16(rtnl_link_bridge_get_priority(_obj))
  }

  public var bridgeCost: UInt32 {
    var cost = UInt32(0)
    let r = rtnl_link_bridge_get_cost(_obj, &cost)
    precondition(r == 0)
    return cost
  }

  public var bridgeFlags: UInt32 {
    UInt32(rtnl_link_bridge_get_flags(_obj))
  }

  public var bridgeHWMode: UInt16 {
    get throws {
      var hwmode = UInt16(0)
      try throwingErrno {
        rtnl_link_bridge_get_hwmode(_obj, &hwmode)
      }
      return hwmode
    }
  }

  public var bridgePVID: UInt16? {
    let pvid = rtnl_link_bridge_pvid(_obj)
    if pvid <= 0 {
      return nil
    }
    return UInt16(pvid)
  }

  public var bridgeHasVLAN: Bool {
    rtnl_link_bridge_has_vlan(_obj) != 0
  }

  public var bridgePortVLAN: rtnl_link_bridge_vlan? {
    guard let p = rtnl_link_bridge_get_port_vlan(_obj) else { return nil }
    return p.pointee
  }
}

public final class RTNLLinkVLAN: RTNLLink {
  public var vlanID: UInt16? {
    let vid = rtnl_link_vlan_get_id(_obj)
    if vid == 0 { return nil }
    return UInt16(vid)
  }

  public var vlanProtocol: UInt16? {
    let proto = rtnl_link_vlan_get_protocol(_obj)
    if proto == 0 { return nil }
    return UInt16(proto)
  }

  public var vlanFlags: UInt32 {
    UInt32(rtnl_link_vlan_get_flags(_obj))
  }
}

public extension NLSocket {
  func enslave(link slave: RTNLLink, to master: RTNLLink) throws {
    try throwingErrno {
      rtnl_link_enslave(_sk, master._obj, slave._obj)
    }
  }

  func release(link slave: RTNLLink) throws {
    try throwingErrno {
      rtnl_link_release(_sk, slave._obj)
    }
  }
}

public enum RTNLLinkMessage: NLObjectConstructible, Sendable {
  case new(RTNLLink)
  case del(RTNLLink)

  init(object: NLObject) throws {
    switch object.messageType {
    case RTM_NEWLINK:
      self = .new(RTNLLink(object: object))
    case RTM_DELLINK:
      self = .del(RTNLLink(object: object))
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
