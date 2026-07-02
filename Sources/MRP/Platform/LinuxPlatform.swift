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

#if os(Linux)

import AsyncAlgorithms
@preconcurrency
import AsyncExtensions
import CLinuxSockAddr
import CNetLink
import Glibc
import IEEE802
import IORing
import IORingUtils
import Logging
import MSTP
import NetLink
import PMC
import SocketAddress
import Synchronization
import SystemPackage

private func _mapUPToSRClassPriority(_ up: UInt8) -> SRclassPriority {
  guard let srClassPriority = SRclassPriority(rawValue: up) else {
    return SRclassPriority.BE // best effort
  }
  return srClassPriority
}

private func _mapSRClassPriorityToUP(_ srClassPriority: SRclassPriority) -> UInt8 {
  srClassPriority.rawValue
}

private extension UInt8 {
  var srClassID: SRclassID? {
    switch self {
    case 2:
      .A // TC2
    case 1:
      .B // TC1
    default:
      nil
    }
  }
}

private extension SRclassID {
  var tc: UInt8 {
    switch self {
    case .A:
      2
    case .B:
      1
    default:
      0
    }
  }
}

// Number of IEEE 802.1Q frame priorities (PCP 0-7).
private let _ieee8021QMaxPriorities = 8

// Replicate the frame-priority -> queue (QPri) distribution performed by the kernel's
// mv88e6xxx_validate_tc_mqprio_avb(): each AVB class maps its PCP to its single reserved
// queue, and the remaining legacy (TC0) PCPs are distributed round-robin across the legacy
// queues. The result is keyed by PCP (0-7) with 0-based queue indices as values, matching the
// DCBNL `dcb_app.priority` semantics for the DCB_APP_SEL_PCP selector. Mirrors the count/offset
// computation in the RTNLMQPrioQDisc convenience initializer so ingress and egress agree.
private func _computeIEEEPriorityMap(
  srClassPriorityMap: SRClassPriorityMap,
  queues: [SRclassID: UInt],
  legacyQueueCount: UInt16?,
  legacyQueueOffset: UInt16?
) -> [UInt8: UInt8] {
  let priorityToTC: [UInt8: UInt8] = Dictionary(
    uniqueKeysWithValues: srClassPriorityMap.map { srClass, srClassPriority in
      (_mapSRClassPriorityToUP(srClassPriority), srClass.tc)
    }
  )

  // 0-based queue (QPri) offset for each AVB traffic class.
  var avbOffset = [UInt8: UInt8]()
  for (srClass, queue) in queues where srClass.tc != 0 {
    precondition(queue > 0 && queue <= UInt(UInt8.max) + 1)
    avbOffset[srClass.tc] = UInt8(queue - 1)
  }

  let tc0Base = Int(legacyQueueOffset ?? 0)
  let legacyCount = max(Int(legacyQueueCount ?? 2), 1)
  // IEEE_8021Q_MAX_PRIORITIES minus the AVB classes; matches the kernel's "- 2".
  let legacyFrameCount = max(_ieee8021QMaxPriorities - srClassPriorityMap.count, 1)
  // DIV_ROUND_UP(legacyFrameCount, legacyCount)
  let tc0FramesPerQueue = max((legacyFrameCount + legacyCount - 1) / legacyCount, 1)

  var map = [UInt8: UInt8]()
  var legacyCounter = 0
  for pcp in UInt8(0)..<UInt8(_ieee8021QMaxPriorities) {
    let tc = priorityToTC[pcp] ?? 0
    if tc == 0 {
      map[pcp] = UInt8(tc0Base + (legacyCounter / tc0FramesPerQueue))
      legacyCounter += 1
    } else {
      map[pcp] = avbOffset[tc] ?? UInt8(tc0Base)
    }
  }
  return map
}

// Build the DCBNL APP table entries (PCP selector, DEI=0) for the ingress PCP -> queue map.
private func _computeIngressDCBApps(
  srClassPriorityMap: SRClassPriorityMap,
  queues: [SRclassID: UInt],
  legacyQueueCount: UInt16?,
  legacyQueueOffset: UInt16?
) -> [RTNLDCBApp] {
  _computeIEEEPriorityMap(
    srClassPriorityMap: srClassPriorityMap,
    queues: queues,
    legacyQueueCount: legacyQueueCount,
    legacyQueueOffset: legacyQueueOffset
  )
  .sorted { $0.key < $1.key }
  .map { pcp, queue in RTNLDCBApp.pcp(pcp, priority: queue) }
}

private func _makeLinkLayerAddress(
  family: sa_family_t = sa_family_t(AF_PACKET),
  macAddress: EUI48? = nil,
  etherType: UInt16 = UInt16(ETH_P_ALL),
  packetType: UInt8 = 0,
  index: Int? = nil
) -> sockaddr_ll {
  var sll = sockaddr_ll()
  sll.sll_family = UInt16(family)
  sll.sll_protocol = etherType.bigEndian
  sll.sll_ifindex = CInt(index ?? 0)
  sll.sll_pkttype = packetType
  if let macAddress {
    sll.sll_halen = UInt8(ETH_ALEN)
    sll.sll_addr.0 = macAddress[0]
    sll.sll_addr.1 = macAddress[1]
    sll.sll_addr.2 = macAddress[2]
    sll.sll_addr.3 = macAddress[3]
    sll.sll_addr.4 = macAddress[4]
    sll.sll_addr.5 = macAddress[5]
  }
  return sll
}

private func _makeLinkLayerAddressBytes(
  family: sa_family_t = sa_family_t(AF_PACKET),
  macAddress: EUI48? = nil,
  etherType: UInt16 = UInt16(ETH_P_ALL),
  packetType: UInt8 = 0,
  index: Int? = nil
) -> [UInt8] {
  var sll = _makeLinkLayerAddress(
    family: family,
    macAddress: macAddress,
    etherType: etherType,
    index: index
  )
  return withUnsafeBytes(of: &sll) {
    Array($0)
  }
}

// TODO: use NetLink to avoid blocking I/O
private func _ethToolIoctl<T>(fileHandle: FileHandle, name: String, arg: inout T) throws {
  guard name.count < Int(IFNAMSIZ) else { throw Errno.outOfRange }

  try withUnsafeMutablePointer(to: &arg) {
    try $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
      var ifr = ifreq()
      ifr.ifr_ifru.ifru_data = UnsafeMutablePointer($0)

      withUnsafeMutablePointer(to: &ifr.ifr_ifrn.ifrn_name) {
        let start = $0.propertyBasePointer(to: \.0)!
        memcpy(start, name, name.count)
      }

      if ioctl(fileHandle.fileDescriptor, UInt(SIOCETHTOOL), &ifr) < 0 {
        throw Errno(rawValue: errno)
      }
    }
  }
}

struct EthernetChannelParameterSet: Sendable {
  let rx: Int
  let tx: Int
  let other: Int
  let combined: Int
}

struct EthernetChannelParameters: Sendable {
  let max: EthernetChannelParameterSet
  let current: EthernetChannelParameterSet

  init(_ channels: ethtool_channels) {
    self.max = EthernetChannelParameterSet(
      rx: Int(channels.max_rx),
      tx: Int(channels.max_tx),
      other: Int(channels.max_other),
      combined: Int(channels.max_combined)
    )
    current = EthernetChannelParameterSet(
      rx: Int(channels.rx_count),
      tx: Int(channels.tx_count),
      other: Int(channels.other_count),
      combined: Int(channels.combined_count)
    )
  }
}

private func _getEthChannelCount(
  fileHandle: FileHandle,
  name: String
) throws -> EthernetChannelParameters {
  var channels = ethtool_channels()
  channels.cmd = UInt32(ETHTOOL_GCHANNELS)
  try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &channels)
  return EthernetChannelParameters(channels)
}

private func _getEthLinkSettings(
  fileHandle: FileHandle,
  name: String
) throws -> (ethtool_link_settings, [UInt32]) {
  var linkSettingsBuffer = [UInt8](
    repeating: 0,
    count: MemoryLayout<ethtool_link_settings>.size + 3 * Int(SCHAR_MAX)
  )
  try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &linkSettingsBuffer)

  return try withUnsafeMutablePointer(to: &linkSettingsBuffer) {
    try $0.withMemoryRebound(to: ethtool_link_settings.self, capacity: 1) { linkSettings in
      guard linkSettings.pointee.link_mode_masks_nwords < 0 && linkSettings.pointee
        .cmd == UInt32(ETHTOOL_GLINKSETTINGS)
      else {
        throw Errno.invalidArgument
      }

      linkSettings.pointee.link_mode_masks_nwords = -linkSettings.pointee.link_mode_masks_nwords
      try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &linkSettings.pointee)

      guard linkSettings.pointee.link_mode_masks_nwords > 0 && linkSettings.pointee
        .cmd == UInt32(ETHTOOL_GLINKSETTINGS)
      else {
        throw Errno.invalidArgument
      }

      // layout is:
      // __u32 reserved[7];
      // __u32 map_supported[link_mode_masks_nwords];
      // __u32 map_advertising[link_mode_masks_nwords];
      // __u32 map_lp_advertising[link_mode_masks_nwords];

      let linkModes = withUnsafePointer(to: &linkSettings.pointee.reserved.6) {
        Array(UnsafeBufferPointer<UInt32>(
          start: $0 + 1,
          count: 3 * Int(linkSettings.pointee.link_mode_masks_nwords)
        ))
      }

      return (linkSettings.pointee, linkModes)
    }
  }
}

private func _getEthLinkSettingsCompat(
  fileHandle: FileHandle,
  name: String
) throws -> (ethtool_link_settings, [UInt32]) {
  var legacyLinkSettings = ethtool_cmd()
  legacyLinkSettings.cmd = UInt32(ETHTOOL_GSET)
  try _ethToolIoctl(fileHandle: fileHandle, name: name, arg: &legacyLinkSettings)

  var linkSettings = ethtool_link_settings()

  linkSettings.cmd = UInt32(ETHTOOL_GLINKSETTINGS)

  linkSettings.speed = UInt32(legacyLinkSettings.speed)
  linkSettings.duplex = legacyLinkSettings.duplex
  linkSettings.port = legacyLinkSettings.port
  linkSettings.phy_address = legacyLinkSettings.phy_address
  linkSettings.autoneg = legacyLinkSettings.autoneg
  linkSettings.mdio_support = legacyLinkSettings.mdio_support
  linkSettings.eth_tp_mdix = legacyLinkSettings.eth_tp_mdix
  linkSettings.eth_tp_mdix_ctrl = legacyLinkSettings.eth_tp_mdix_ctrl

  let linkModes: [UInt32] = [
    legacyLinkSettings.supported,
    legacyLinkSettings.advertising,
    legacyLinkSettings.lp_advertising,
  ]

  return (linkSettings, linkModes)
}

public struct LinuxPort: Port, AVBPort, Sendable, CustomStringConvertible {
  public static var now: ContinuousClock.Instant { .now }

  public typealias ID = Int

  public static func == (lhs: LinuxPort, rhs: LinuxPort) -> Bool {
    lhs.id == rhs.id
  }

  fileprivate let _rtnl: RTNLLink
  fileprivate let _txSocket: Socket
  private let _linkSettings: (ethtool_link_settings, [UInt32])
  private let _channels: EthernetChannelParameters?
  fileprivate weak var _bridge: LinuxBridge?

  init(rtnl: RTNLLink, bridge: LinuxBridge) throws {
    _rtnl = rtnl
    _bridge = bridge
    _txSocket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_PACKET), type: SOCK_RAW)
    // shouldn't need to join multicast group if we are only sending packets

    let fileHandle = try FileHandle(
      fileDescriptor: socket(CInt(AF_PACKET), Int32(SOCK_DGRAM.rawValue), 0),
      closeOnDealloc: true
    )

    do {
      _linkSettings = try _getEthLinkSettings(fileHandle: fileHandle, name: _rtnl.name)
    } catch {
      do {
        _linkSettings = try _getEthLinkSettingsCompat(fileHandle: fileHandle, name: _rtnl.name)
      } catch {
        debugPrint("LinuxBridge: failed to get link settings for \(_rtnl.name): \(error), ignoring")
        _linkSettings = (ethtool_link_settings(), [0, 0, 0])
      }
    }

    // we allow this to fail, port won't be AVB capable but that is OK
    _channels = try? _getEthChannelCount(fileHandle: fileHandle, name: _rtnl.name)
  }

  public var description: String {
    name
  }

  public func hash(into hasher: inout Hasher) {
    id.hash(into: &hasher)
  }

  public var isOperational: Bool {
    _rtnl.flags & IFF_RUNNING != 0
  }

  public var isEnabled: Bool {
    _rtnl.flags & IFF_UP != 0
  }

  public var isPointToPoint: Bool {
    _operPointToPointMAC || _rtnl.flags & IFF_POINTOPOINT != 0
  }

  // A bridge member's BR_STATE_*; non-members (no master) are always Forwarding. With STP
  // disabled the kernel reports member ports as Forwarding, so gating is a no-op then. This
  // is a synchronous read of the cached netlink link object — no actor transition.
  public var stpPortState: STPPortState {
    guard _rtnl.master != 0, let brport = _rtnl as? RTNLLinkBridge else { return .forwarding }
    switch brport.bridgePortState {
    case 1: return .listening
    case 2: return .learning
    case 3: return .forwarding
    case 4: return .blocking
    default: return .disabled
    }
  }

  private var _operPointToPointMAC: Bool {
    _linkSettings.0.duplex == DUPLEX_FULL
  }

  public var _isBridgeSelf: Bool {
    _isBridge && _rtnl.master == _rtnl.index
  }

  public var _isBridge: Bool {
    _rtnl is RTNLLinkBridge
  }

  public var _isVLAN: Bool {
    _rtnl is RTNLLinkVLAN
  }

  public var name: String {
    _rtnl.name
  }

  public var id: Int {
    _rtnl.index
  }

  public var macAddress: EUI48 {
    _rtnl.address!
  }

  public var pvid: UInt16? {
    // Live PVID, falling back to the frozen AF_BRIDGE snapshot.
    _bridge?._portPVID.withLock { $0[id] } ?? _pvid
  }

  public var vlans: Set<VLAN> {
    // Live VLANs: seeded when the port is registered and kept current by
    // RTM_NEWVLAN/DELVLAN, so runtime removals are reflected. Falls back to
    // the frozen _rtnl snapshot before the bridge has seeded the live map.
    let vids = _bridge?._portVLANs.withLock { $0[id].map { Set($0.keys) } } ?? _vlans ?? []
    return Set(vids.map { VLAN(id: $0) })
  }

  public var dynamicVlans: Set<VLAN> {
    // The subset of vlans carrying BRIDGE_VLAN_INFO_DYNAMIC (802.1Q Dynamic VLAN
    // Registration Entries); empty on kernels without the flag.
    let vids = _bridge?._portVLANs
      .withLock { $0[id].map { Set($0.filter(\.value).keys) } } ?? []
    return Set(vids.map { VLAN(id: $0) })
  }

  public var mtu: UInt {
    _rtnl.mtu
  }

  public var linkSpeed: UInt {
    UInt(_linkSettings.0.speed) * 1000
  }

  public var isAvbCapable: Bool {
    // an MTU above the AVB max frame size can't bound stream latency, so such a port is not AVB
    // capable (IEEE 802.1BA / 802.1Q 35.2.2.8.4)
    guard _rtnl.mtu <= AVBMaxFrameSize else { return false }
    guard let _channels else { return false }
    return _channels.current.tx > 2 || _channels.current.combined > 2
  }

  private func _getMeanLinkDelay() async throws -> PTP.TimeInterval {
    guard let _bridge else { throw MRPError.internalError }
    let portNumber = try await _bridge._getPtpPortProperties(for: self).portIdentity.portNumber
    let portDataSet = try await _bridge._pmc.getPortDataSet(portNumber: portNumber)
    return portDataSet.meanLinkDelay
  }

  public func getPortTcMaxLatency(for _: SRclassPriority) async -> Int {
    // The knowable per-hop terms (b/c/d/e) don't depend on the SR class -- only term a) does, and
    // that one isn't observable here (see srpPortTcMaxLatency), so the class argument is unused.
    // Wire propagation (d): gPTP meanLinkDelay (PTP timeinterval is ns * 2^16), or the spec's
    // 500 ns default when gPTP can't supply a usable (non-negative) value (35.2.2.8.6 d).
    let meanLinkDelayNs = if let meanLinkDelay = try? await _getMeanLinkDelay(),
                             meanLinkDelay >= 0
    {
      Int(meanLinkDelay >> 16)
    } else {
      500
    }
    return srpPortTcMaxLatency(meanLinkDelayNs: meanLinkDelayNs, linkSpeedKbps: linkSpeed)
  }

  public var isAsCapable: Bool {
    get async throws {
      guard let _bridge else { throw MRPError.internalError }
      let portNumber = try await _bridge._getPtpPortProperties(for: self).portIdentity.portNumber
      let portDataSet = try await _bridge._pmc.getPortDataSetNP(portNumber: portNumber)
      return portDataSet.asCapable != 0
    }
  }

  public var pfcEnabledPriorities: Set<SRclassPriority> {
    // ieee_pfc.pfc_en (DCB_CMD_IEEE_GET): a bitmap of priorities with PFC enabled. Best-effort —
    // a switch/kernel without DCBNL PFC support reports none rather than blocking SRP.
    get async throws {
      guard let bridge = _bridge,
            let pfcEnabled = try? await _rtnl.getDCBPFCEnabled(socket: bridge._nlLinkSocket)
      else { return [] }
      return Set((0..<8).compactMap { priority in
        pfcEnabled & (1 << priority) != 0 ? SRclassPriority(rawValue: priority) : nil
      })
    }
  }

  public func setMulticastFlooding(_ enabled: Bool) async throws {
    guard let _bridge else { throw MRPError.internalError }
    try await _rtnl.set(option: .mcastFlood, enabled, socket: _bridge._nlLinkSocket)
  }

  public func setFlowControl(_ enabled: Bool) async throws {
    let fileHandle = try FileHandle(
      fileDescriptor: socket(CInt(AF_PACKET), Int32(SOCK_DGRAM.rawValue), 0),
      closeOnDealloc: true
    )
    var pause = ethtool_pauseparam()
    pause.cmd = UInt32(ETHTOOL_SPAUSEPARAM)
    // Turn autonegotiation off so rx/tx are honored directly: 0/0 forces 802.3x
    // PAUSE off, which the mv88e6xxx driver propagates to the port's ForcedFC bits
    // so a received PAUSE cannot stall reserved egress. Re-enabling restores
    // autonegotiated symmetric pause (the pre-reservation default).
    pause.autoneg = enabled ? 1 : 0
    pause.rx_pause = enabled ? 1 : 0
    pause.tx_pause = enabled ? 1 : 0
    do {
      try _ethToolIoctl(fileHandle: fileHandle, name: _rtnl.name, arg: &pause)
    } catch let error as Errno where error == .notSupported {
      // ENOTSUP == EOPNOTSUPP on Linux, so this catches the driver's -EOPNOTSUPP.
      // Port has no configurable pause (fixed-link, or a MAC that does not
      // advertise symmetric pause); surface as notSupported so MSRP soft-fails and
      // stops retrying. (An unpatched mv88e6xxx instead accepts the ioctl and
      // silently ignores it, which is why the kernel-side fix is also required.)
      throw MRPError.notSupported
    }
  }
}

private extension LinuxPort {
  var _vlans: Set<UInt16>? {
    (_rtnl as? RTNLLinkBridge)?.bridgeTaggedVLANs
  }

  var _untaggedVlans: Set<UInt16>? {
    (_rtnl as? RTNLLinkBridge)?.bridgeUntaggedVLANs
  }

  var _pvid: UInt16? {
    (_rtnl as? RTNLLinkBridge)?.bridgePVID
  }

  // dynamic marks a Dynamic VLAN Registration Entry (a peer MVRP registration); older
  // kernels silently ignore the flag
  func _add(vlan: VLAN, dynamic: Bool) async throws {
    guard let rtnl = _rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }

    var flags: BridgeVLANFlags = dynamic ? .dynamic : []

    if _untaggedVlans?.contains(vlan.vid) ?? false {
      // preserve untagging status, this may not be on spec but saves blowing away management
      // interface
      flags.insert(.untagged)
    }
    if _pvid == vlan.vid {
      flags.insert(.pvid)
    }

    try await rtnl.add(vlans: Set([vlan.vid]), flags: flags, socket: _bridge!._nlLinkSocket)
  }

  func _remove(vlan: VLAN) async throws {
    guard let rtnl = _rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }

    try await rtnl.remove(vlans: Set([vlan.vid]), socket: _bridge!._nlLinkSocket)
  }
}

public actor LinuxBridge: Bridge, CustomStringConvertible {
  public typealias P = LinuxPort

  fileprivate let _nlLinkSocket: NLSocket
  private let _nlNfLog: NFNLLog
  private let _nlQDiscHandle: UInt16?
  private var _nlNfLogMonitorTask: Task<(), Error>!
  private var _nlLinkMonitorTask: Task<(), Error>!
  private let _bridgeName: String
  private var _bridgeIndex: Int = 0
  private var _bridgePort: P?
  // Per-port tagged VLANs (VID -> BRIDGE_VLAN_INFO_DYNAMIC), keyed by port ifindex:
  // seeded from the RTM_GETVLAN dump at startup (the libnl bitmaps carry no flags) and
  // kept live by VLAN DB notifications; _rtnl is a frozen snapshot that won't reflect
  // later changes. The dynamic flag marks 802.1Q Dynamic VLAN Registration Entries
  // (e.g. our own MVRP-created entries); it is never set on kernels without the flag.
  // A Mutex so LinuxPort.vlans can read it synchronously.
  let _portVLANs = Mutex<[Int: [UInt16: Bool]]>([:])
  // Per-port PVID by ifindex; seeded from the AF_BRIDGE dump, kept live by VLAN DB.
  let _portPVID = Mutex<[Int: UInt16]>([:])
  private let _portNotificationChannel = AsyncChannel<PortNotification<P>>()
  private let _rxPacketsChannel = AsyncThrowingChannel<(P.ID, IEEE802Packet), Error>()
  private var _linkLocalRegistrations = Set<FilterRegistration>()
  private var _linkLocalRxTasks = [LinkLocalRXTaskKey: Task<(), Error>]()
  // A buffered stream (not a rendezvous channel): yields never block the link
  // monitor, so a missing consumer (MSRP disabled, the default) cannot wedge it.
  private let _srClassPriorityMapStream: AsyncStream<SRClassPriorityMapNotification<P>>
  private let _srClassPriorityMapContinuation:
    AsyncStream<SRClassPriorityMapNotification<P>>.Continuation
  // Buffered like _srClassPriorityMapStream: a per-port ping on static VLAN membership change,
  // consumed by MVRP to update its declarations. Harmless if MVRP is disabled.
  private let _vlanRegistrationStream: AsyncStream<VLANRegistrationNotification<P>>
  private let _vlanRegistrationContinuation:
    AsyncStream<VLANRegistrationNotification<P>>.Continuation
  fileprivate let _pmc: PTPManagementClient
  private var _portPropertiesCache = [P.ID: PortPropertiesNP]()
  private let _portExclusions: Set<String>
  // Member ports for which the ingress (DCBNL) PCP->queue map is currently configured, and
  // whether the switch uses a single global ingress priority map shared by all ports.
  //
  // Some switches (e.g. 88E6352) have a global map: the kernel mirrors DCBNL APP entries to
  // every user port, rejects duplicates with EEXIST, and does not refcount. Others (e.g.
  // 88E6390/6393x) have per-port maps. We program every member port until an add returns
  // EEXIST, which tells us the map is global; from then on we program/tear down the shared map
  // exactly once, on the first/last member port. See configureIngressQueues(port:...).
  private var _ingressQueuePorts = Set<P.ID>()
  private var _ingressMappingIsGlobal = false
  private let _logger: Logger

  public init(
    name: String,
    netFilterGroup group: Int,
    qDiscHandle: UInt16? = nil,
    ptpManagementClientSocketPath: String? = nil,
    portExclusions: Set<String> = [],
    logger: Logger
  ) async throws {
    _bridgeName = name
    _nlLinkSocket = try NLSocket(protocol: NETLINK_ROUTE)
    _nlNfLog = try NFNLLog(group: UInt16(group))
    _nlQDiscHandle = qDiscHandle
    _pmc = try await PTPManagementClient(path: ptpManagementClientSocketPath)
    _portExclusions = portExclusions
    _logger = logger
    (_srClassPriorityMapStream, _srClassPriorityMapContinuation) = AsyncStream.makeStream(
      of: SRClassPriorityMapNotification<P>.self,
      bufferingPolicy: .bufferingNewest(64)
    )
    (_vlanRegistrationStream, _vlanRegistrationContinuation) = AsyncStream.makeStream(
      of: VLANRegistrationNotification<P>.self,
      bufferingPolicy: .bufferingNewest(256)
    )
  }

  public nonisolated var description: String {
    _bridgeName
  }

  private func _handleLinkNotification(_ linkMessage: RTNLLinkMessage) async throws {
    var portNotification: PortNotification<P>?
    let port = try P(rtnl: linkMessage.link, bridge: self)
    if port._isBridgeSelf, port._rtnl.index == _bridgeIndex {
      if case .new = linkMessage {
        _bridgePort = port
      } else {
        _logger.debug("LinuxBridge: bridge device itself removed")
        throw Errno.noSuchAddressOrDevice
      }
    } else if port._rtnl.master == _bridgeIndex {
      if case .new = linkMessage {
        portNotification = .added(port)
        // seed the live VLAN map from the link's AF_BRIDGE info unless VLAN DB
        // notifications have already populated it (they are the fresher source, and
        // carry the dynamic flag, which the libnl bitmaps do not)
        _portVLANs.withLock { map in
          if map[port.id] == nil {
            map[port.id] = .init(uniqueKeysWithValues: (port._vlans ?? []).map { ($0, false) })
          }
        }
        if !_portExclusions.contains(port.name) {
          try _addLinkLocalRxTask(port: port)
        }
      } else {
        try _cancelLinkLocalRxTask(port: port)
        _portPropertiesCache[port.id] = nil
        _portVLANs.withLock { $0[port.id] = nil }
        _portPVID.withLock { $0[port.id] = nil }
        portNotification = .removed(port)
      }
    } else {
      _logger.debug(
        "LinuxBridge: ignoring port \(port) at index \(port._rtnl.index), not a member or self"
      )
    }
    if let portNotification {
      await _portNotificationChannel.send(portNotification)
    }
  }

  public nonisolated var notifications: AnyAsyncSequence<PortNotification<P>> {
    _portNotificationChannel.eraseToAnyAsyncSequence()
  }

  // Poll mstpd over its control socket for the port's CIST role/state. Soft-fails to nil if
  // mstpd is absent; a fresh connection per call keeps it robust to mstpd restarts (this is
  // only invoked on port events, not on the hot path).
  public func getStpPortStatus(port: P) async -> STPPortStatus? {
    guard _bridgeIndex != 0, let client = try? await MSTPControlClient() else { return nil }
    return await client.cistPortStatus(
      bridgeIndex: Int32(_bridgeIndex),
      portIndex: Int32(port.id)
    )?.stpPortStatus
  }

  private func _handleTCNotification(_ tcMessage: RTNLTCMessage) async throws {
    // all we are really interested is in SR class remappings
    guard let qDisc = tcMessage.tc as? RTNLMQPrioQDisc,
          let _nlQDiscHandle,
          qDisc.handle >> 16 == _nlQDiscHandle,
          let srClassPriorityMap = qDisc.srClassPriorityMap else { return }
    let tcNotification: SRClassPriorityMapNotification<P> = if case .new = tcMessage {
      .added(srClassPriorityMap)
    } else {
      .removed(srClassPriorityMap)
    }
    _srClassPriorityMapContinuation.yield(tcNotification)
  }

  private func _handleVLANNotification(_ vlanMessage: RTNLVLANDBMessage) {
    let vlandb = vlanMessage.vlandb
    // Track tagged VLANs only (port.vlans mirrors bridgeTaggedVLANs; the SR
    // class VLAN is tagged), keyed by port ifindex.
    let taggedVids = Set(vlandb.entries.filter { !$0.isUntagged }.map(\.vid))
    let isNew = switch vlanMessage {
    case .new: true
    case .del: false
    }
    _portVLANs.withLock { map in
      if isNew {
        // a re-add updates the dynamic flag (a static re-add promotes a dynamic entry)
        for entry in vlandb.entries where !entry.isUntagged {
          map[vlandb.ifIndex, default: [:]][entry.vid] = entry.isDynamic
        }
      } else {
        // keep an empty map rather than removing the key: the key marks the port as
        // seeded, so port.vlans must not fall back to the stale frozen snapshot
        for vid in taggedVids {
          map[vlandb.ifIndex]?[vid] = nil
        }
      }
    }
    // Keep the per-port PVID live.
    if isNew, let pvid = vlandb.entries.first(where: { $0.isPVID })?.vid {
      _portPVID.withLock { $0[vlandb.ifIndex] = pvid }
    }
    _logger.debug(
      "LinuxBridge: VLAN \(isNew ? "new" : "del") on ifindex \(vlandb.ifIndex): \(vlandb.entries)"
    )
    // Ping MVRP to update declarations to the updated static membership.
    _vlanRegistrationContinuation.yield(VLANRegistrationNotification(portID: vlandb.ifIndex))
  }

  public func getVlans(controller: isolated MRPController<P>) async -> Set<VLAN> {
    if let vlans = await _bridgePort?._vlans {
      Set(vlans.map { VLAN(vid: $0) })
    } else {
      Set()
    }
  }

  public var name: String {
    _bridgePort!.name
  }

  private func _getPorts(family: sa_family_t) async throws -> Set<P> {
    try await Set(
      _nlLinkSocket.getLinks(family: family).map { try P(rtnl: $0, bridge: self) }
        .collect()
    )
  }

  private func _getMemberPorts() async throws -> Set<P> {
    try await _getPorts(family: sa_family_t(AF_BRIDGE)).filter {
      !$0._isBridgeSelf && $0._rtnl.master == _bridgeIndex
    }
  }

  private func _getBridgePort(name: String) async throws -> P {
    let bridgePorts = try await _getPorts(family: sa_family_t(AF_BRIDGE))
      .filter { $0._isBridgeSelf && $0.name == name }
    guard bridgePorts.count == 1 else {
      throw MRPError.invalidBridgeIdentity
    }
    return bridgePorts.first!
  }

  package var bridgePort: P {
    _bridgePort!
  }

  private struct LinkLocalRXTaskKey: Hashable {
    let portID: P.ID
    let filterRegistration: FilterRegistration
  }

  private func _allocateLinkLocalRxTask(
    port: P,
    filterRegistration: FilterRegistration
  ) -> Task<(), Error> {
    Task {
      // backoff between rebuilds, escalating so a *permanent* failure (the socket can't be
      // re-created at all) can't spin the loop at ~1 kHz. A successful recv run resets it.
      var backoffMs: UInt = 1
      let backoffCapMs: UInt = 1024
      repeat {
        do {
          for try await packet in try await filterRegistration._rxPackets(port: port) {
            await _rxPacketsChannel.send((port.id, packet))
          }
          backoffMs = 1 // the recv loop ran; a later failure is a fresh transient
        } catch Errno.interrupted {
          // restart on interrupted system call
        } catch {
          // a port link flap makes io_uring cancel the in-flight recv (ECANCELED); rebuild
          // the socket rather than let reception die permanently. The backoff caps a
          // pathological immediate re-throw (the normal rebuild blocks in recv).
          guard !Task.isCancelled else { break }
          _logger.debug(
            "LinuxBridge: rebuilding link-local RX for \(port) \(filterRegistration) after \(error) (backoff \(backoffMs)ms)"
          )
          try? await Task.sleep(for: .milliseconds(backoffMs), clock: .continuous)
          backoffMs = min(backoffMs * 2, backoffCapMs)
        }
      } while !Task.isCancelled
    }
  }

  private func _hasLinkLocalRxTasks(port: P) -> Bool {
    !_linkLocalRegistrations.isEmpty && _linkLocalRegistrations.allSatisfy { filterRegistration in
      let key = LinkLocalRXTaskKey(portID: port.id, filterRegistration: filterRegistration)
      return _linkLocalRxTasks[key] != nil
    }
  }

  private func _addLinkLocalRxTask(port: P) throws {
    precondition(!port._isBridgeSelf)
    guard !_hasLinkLocalRxTasks(port: port) else { return }
    try? _cancelLinkLocalRxTask(port: port)
    for filterRegistration in _linkLocalRegistrations {
      let key = LinkLocalRXTaskKey(portID: port.id, filterRegistration: filterRegistration)
      _linkLocalRxTasks[key] = _allocateLinkLocalRxTask(
        port: port,
        filterRegistration: filterRegistration
      )
      _logger.debug(
        "LinuxBridge: started link-local RX task for \(port) filter registration \(filterRegistration)"
      )
    }
  }

  private func _cancelLinkLocalRxTask(port: P) throws {
    precondition(!port._isBridgeSelf)
    try _cancelLinkLocalRxTask(portID: port.id)
  }

  private func _cancelLinkLocalRxTask(portID: P.ID) throws {
    for filterRegistration in _linkLocalRegistrations {
      let key = LinkLocalRXTaskKey(portID: portID, filterRegistration: filterRegistration)
      guard let index = _linkLocalRxTasks.index(forKey: key) else { continue }
      let task = _linkLocalRxTasks[index].value
      _linkLocalRxTasks.remove(at: index)
      task.cancel()
      _logger.debug(
        "LinuxBridge: removed link-local RX task for \(portID) filter registration \(filterRegistration)"
      )
    }
  }

  public func register(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: MRPController<P>
  ) async throws {
    guard _isLinkLocal(macAddress: groupAddress) else { return }
    _linkLocalRegistrations.insert(FilterRegistration(
      groupAddress: groupAddress,
      etherType: etherType
    ))
  }

  public func deregister(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: MRPController<P>
  ) async throws {
    guard _isLinkLocal(macAddress: groupAddress) else { return }
    _linkLocalRegistrations.remove(FilterRegistration(
      groupAddress: groupAddress,
      etherType: etherType
    ))
  }

  public func run(controller: MRPController<P>) async throws {
    _bridgePort = try await _getBridgePort(name: _bridgeName)
    _bridgeIndex = _bridgePort!._rtnl.index

    try _nlLinkSocket.subscribeLinks()
    try _nlLinkSocket.subscribeTC()
    try _nlLinkSocket.subscribeBridgeVLANs()

    _nlLinkMonitorTask = Task<(), Error> { [self] in
      for try await notification in _nlLinkSocket.notifications {
        do {
          switch notification {
          case let linkNotification as RTNLLinkMessage:
            try await _handleLinkNotification(linkNotification)
          case let tcNotification as RTNLTCMessage:
            try await _handleTCNotification(tcNotification)
          case let vlanNotification as RTNLVLANDBMessage:
            _handleVLANNotification(vlanNotification)
          default:
            break
          }
        } catch Errno.noSuchAddressOrDevice {
          throw Errno.noSuchAddressOrDevice
        } catch {}
      }
    }
    _nlNfLogMonitorTask = Task<(), Error> { [self] in
      for try await packet in _nfNlLogRxPackets {
        await _rxPacketsChannel.send(packet)
      }
    }

    // Seed the live VLAN map from an RTM_GETVLAN dump: unlike the libnl AF_BRIDGE
    // bitmaps this carries the per-VID flags, so dynamic (protocol-created) entries
    // left over from a previous run are recognised as such and not treated as static.
    if let vlandbs = try? await _nlLinkSocket.getBridgeVLANs() {
      do {
        for try await vlandb in vlandbs {
          let entries = vlandb.entries.filter { !$0.isUntagged }
          _portVLANs.withLock {
            $0[vlandb.ifIndex] = Dictionary(
              entries.map { ($0.vid, $0.isDynamic) },
              uniquingKeysWith: { $0 || $1 }
            )
          }
        }
      } catch {
        _logger.info("LinuxBridge: VLAN DB dump failed, falling back to AF_BRIDGE info")
      }
    }

    let ports = try await _getMemberPorts()
    for port in ports {
      if let pvid = port._pvid { _portPVID.withLock { $0[port.id] = pvid } }
      // fall back to the (flagless) AF_BRIDGE info for ports the dump did not cover
      _portVLANs.withLock { map in
        if map[port.id] == nil {
          map[port.id] = .init(uniqueKeysWithValues: (port._vlans ?? []).map { ($0, false) })
        }
      }
      await _portNotificationChannel.send(.added(port))
      if !_portExclusions.contains(port.name) {
        try _addLinkLocalRxTask(port: port)
      }
    }
  }

  private func _shutdown() throws {
    let portIDs = _linkLocalRxTasks.keys.map(\.portID)
    for portID in portIDs {
      try? _cancelLinkLocalRxTask(portID: portID)
    }

    _nlNfLogMonitorTask?.cancel()
    _nlLinkMonitorTask?.cancel()

    try? _nlLinkSocket.unsubscribeBridgeVLANs()
    try? _nlLinkSocket.unsubscribeTC()
    try? _nlLinkSocket.unsubscribeLinks()

    _bridgePort = nil
    _bridgeIndex = 0
  }

  public func shutdown(controller: MRPController<P>) async throws {
    try _shutdown()
  }

  public func tx(
    _ packet: IEEE802Packet,
    on port: P,
    controller: MRPController<P>
  ) async throws {
    let address = _makeLinkLayerAddressBytes(
      macAddress: packet.destMacAddress,
      etherType: packet.etherType,
      index: port.id
    )

    var serializationContext = SerializationContext()
    try packet.serialize(into: &serializationContext)
    try await port._txSocket.sendMessage(.init(
      name: address,
      buffer: serializationContext.bytes
    ))
  }

  public nonisolated var rxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)> {
    _rxPacketsChannel.eraseToAnyAsyncSequence()
  }

  private var _nfNlLogRxPackets: AnyAsyncSequence<(P.ID, IEEE802Packet)> {
    _nlNfLog.logMessages.compactMap { logMessage in
      guard let hwHeader = logMessage.hwHeader, let payload = logMessage.payload,
            let packet = try? IEEE802Packet(hwHeader: hwHeader, payload: payload)
      else {
        return nil
      }
      return (logMessage.physicalInputDevice, packet)
    }.eraseToAnyAsyncSequence()
  }
}

fileprivate final class FilterRegistration: Equatable, Hashable, Sendable, CustomStringConvertible {
  static func == (lhs: FilterRegistration, rhs: FilterRegistration) -> Bool {
    _isEqualMacAddress(lhs._groupAddress, rhs._groupAddress) && lhs._etherType == rhs._etherType
  }

  let _groupAddress: EUI48
  let _etherType: UInt16

  init(groupAddress: EUI48, etherType: UInt16) {
    _groupAddress = groupAddress
    _etherType = etherType
  }

  func hash(into hasher: inout Hasher) {
    _hashMacAddress(_groupAddress, into: &hasher)
    _etherType.hash(into: &hasher)
  }

  var description: String {
    "FilterRegistration(_groupAddress: \(_macAddressToString(_groupAddress)), _etherType: \(_formatHex(_etherType, padToWidth: 4)))"
  }

  func _rxPackets(port: LinuxPort) async throws -> AnyAsyncSequence<IEEE802Packet> {
    precondition(_isLinkLocal(macAddress: _groupAddress))
    let rxSocket = try Socket(
      ring: IORing.shared,
      domain: sa_family_t(AF_PACKET),
      type: SOCK_RAW,
      protocol: CInt(_etherType.bigEndian)
    )
    try rxSocket.bind(to: _makeLinkLayerAddress(
      macAddress: port.macAddress,
      etherType: _etherType,
      packetType: UInt8(PACKET_MULTICAST),
      index: port.id
    ))
    try rxSocket.addMulticastMembership(for: _makeLinkLayerAddress(
      macAddress: _groupAddress,
      index: port.id
    ))

    return try await rxSocket.receiveMessages(count: Int(port._rtnl.mtu), capacity: 32)
      .compactMap { message in
        try? message.buffer.withParserSpan { input in
          try IEEE802Packet(parsing: &input)
        }
      }.eraseToAnyAsyncSequence()
  }
}

extension LinuxBridge: MMRPAwareBridge {
  func register(
    macAddress: EUI48,
    vlan: VLAN?,
    flags: MMRPRegistrationFlags,
    on ports: Set<P>
  ) async throws {
    guard let rtnl = bridgePort._rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }
    let state: RTNLLinkBridge.MDBState =
      flags.contains(.dynamicReservation) ? .dynamicReservation : .permanent
    for port in ports {
      if _isMulticast(macAddress: macAddress) {
        do {
          try await rtnl.add(
            link: port._rtnl,
            groupAddresses: [macAddress],
            vlanID: vlan?.vid,
            state: state,
            socket: _nlLinkSocket
          )
        } catch where state == .dynamicReservation {
          // Kernels predating MDB_DYNAMIC_RESERVATION reject the state value;
          // fall back to a permanent entry so non-conformant kernels still get
          // the MDB entry installed (without the 802.1Qat reserved-stream mark).
          _logger.debug(
            "LinuxBridge: failed to add dynamic reservation MDB entry for \(_macAddressToString(macAddress)) on \(port): \(error); falling back to permanent entry"
          )
          try await rtnl.add(
            link: port._rtnl,
            groupAddresses: [macAddress],
            vlanID: vlan?.vid,
            state: .permanent,
            socket: _nlLinkSocket
          )
        }
      } else {
        try await rtnl.add(link: port._rtnl, fdbEntry: macAddress, socket: _nlLinkSocket)
      }
    }
  }

  func deregister(macAddress: EUI48, vlan: VLAN?, from ports: Set<P>) async throws {
    guard let rtnl = bridgePort._rtnl as? RTNLLinkBridge else { throw Errno.noSuchAddressOrDevice }
    for port in ports {
      if _isMulticast(macAddress: macAddress) {
        try await rtnl.remove(
          link: port._rtnl,
          groupAddresses: [macAddress],
          vlanID: vlan?.vid,
          socket: _nlLinkSocket
        )
      } else {
        try await rtnl.remove(link: port._rtnl, fdbEntry: macAddress, socket: _nlLinkSocket)
      }
    }
  }

  func register(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue,
    on ports: Set<P>
  ) async throws {}

  func deregister(
    serviceRequirement requirementSpecification: MMRPServiceRequirementValue,
    from ports: Set<P>
  ) async throws {}
}

extension LinuxBridge: MVRPAwareBridge {
  nonisolated var vlanRegistrationNotifications: AnyAsyncSequence<VLANRegistrationNotification<P>> {
    _vlanRegistrationStream.eraseToAnyAsyncSequence()
  }

  func register(vlan: VLAN, on port: P, static isStatic: Bool) async throws {
    try await port._add(vlan: vlan, dynamic: !isStatic)
  }

  func deregister(vlan: VLAN, from port: P) async throws {
    try await port._remove(vlan: vlan)
  }
}

private extension SRClassPriorityMap {
  var lowestClassID: SRclassID {
    SRclassID(rawValue: keys.map(\.rawValue).sorted().first!)!
  }
}

extension LinuxBridge: MSRPAwareBridge {
  // Compute the legacy (TC0) queue count and base offset for a port, shared by the egress
  // (MQPRIO) and ingress (DCBNL) queue configuration so both derive identical mappings.
  private func _legacyQueueParams(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt], // map a SR class (TC) to a queue number
    forceAvbCapable: Bool
  ) throws -> (count: UInt16?, offset: UInt16?) {
    // The legacy (TC0) queues are the queues not claimed by an AVB class. Derive
    // this from the SR-class queue assignment rather than the port's reported TX
    // queue count: numTXQueues is unreliable on some switches (88E6352 -- the same
    // reason --force-avb-capable is needed), and unlike egress (an MQPRIO qdisc in
    // DCB mode, where the driver supplies the real queue layout), the ingress DCB
    // path writes these QPri values straight to the switch, which rejects an
    // out-of-range value with EINVAL. numTXQueues is consulted only to size the
    // legacy block in the inverted (i210) layout, where it is reported reliably.
    let avbQueueIndices = queues.compactMap { srClass, queue -> Int? in
      srClass.tc != 0 ? Int(queue) - 1 : nil
    }.sorted()

    guard let lowestAvb = avbQueueIndices.first, let highestAvb = avbQueueIndices.last else {
      return (nil, nil) // no AVB classes; fall back to defaults
    }

    if lowestAvb > 0 {
      // Normal layout: AVB classes occupy the top queues, legacy is [0, lowestAvb).
      // Independent of numTXQueues.
      return (UInt16(lowestAvb), 0)
    }

    // Inverted (i210) layout: AVB classes occupy the bottom queues, legacy is
    // [highestAvb + 1, numTXQueues), so we need the real queue count here.
    let numTXQueues = Int(port._rtnl.numTXQueues)
    guard numTXQueues > highestAvb + 1 else {
      guard forceAvbCapable else {
        throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
      }
      return (nil, nil)
    }
    return (UInt16(numTXQueues - (highestAvb + 1)), UInt16(highestAvb + 1))
  }

  func configureEgressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt], // map a SR class (TC) to a queue number
    forceAvbCapable: Bool
  ) async throws {
    guard let _nlQDiscHandle else {
      throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
    }

    let (legacyQueueCount, legacyQueueOffset) = try _legacyQueueParams(
      port: port,
      srClassPriorityMap: srClassPriorityMap,
      queues: queues,
      forceAvbCapable: forceAvbCapable
    )

    let mqprio = try RTNLMQPrioQDisc(
      handle: UInt32(_nlQDiscHandle) << 16,
      parent: UInt32.max,
      srClassPriorityMap: srClassPriorityMap,
      queues: queues,
      legacyQueueCount: legacyQueueCount,
      legacyQueueOffset: legacyQueueOffset
    )

    try await port._rtnl.add(mqprio: mqprio, socket: _nlLinkSocket)
  }

  func unconfigureEgressQueues(
    port: P
  ) async throws {
    guard let _nlQDiscHandle else {
      throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
    }

    try await port._rtnl.remove(
      mqprio: RTNLMQPrioQDisc(handle: UInt32(_nlQDiscHandle) << 16, parent: UInt32.max),
      socket: _nlLinkSocket
    )
  }

  private func _ingressDCBApps(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) throws -> [RTNLDCBApp] {
    // Shares _legacyQueueParams with the egress MQPRIO path so the ingress QPri
    // values always match the queues MQPRIO programs for egress.
    let (legacyQueueCount, legacyQueueOffset) = try _legacyQueueParams(
      port: port,
      srClassPriorityMap: srClassPriorityMap,
      queues: queues,
      forceAvbCapable: forceAvbCapable
    )

    return _computeIngressDCBApps(
      srClassPriorityMap: srClassPriorityMap,
      queues: queues,
      legacyQueueCount: legacyQueueCount,
      legacyQueueOffset: legacyQueueOffset
    )
  }

  func configureIngressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) async throws {
    let apps = try _ingressDCBApps(
      port: port,
      srClassPriorityMap: srClassPriorityMap,
      queues: queues,
      forceAvbCapable: forceAvbCapable
    )

    let wasEmpty = _ingressQueuePorts.isEmpty
    _ingressQueuePorts.insert(port.id)

    if _ingressMappingIsGlobal { return }

    // Reconcile rather than blindly add. DCBNL keys APP entries on (selector, protocol,
    // priority): adding an entry that already exists fails with EEXIST, and adding a PCP whose
    // priority merely differs from a stale entry silently leaves *both* (the duplicate
    // 0nd:0/0nd:1 seen in testing). So read the current PCP map, delete entries that are not in
    // the desired set (stale priorities / leftovers from a previous daemon), and add only the
    // ones that are missing. This is idempotent and the same effect as `dcb app replace`.
    let currentPCP = await ((try? port._rtnl.getDCBApps(socket: _nlLinkSocket)) ?? [])
      .filter { $0.selector == RTNLDCBApp.pcpSelector }

    // A global-map switch (e.g. 88E6352) mirrors APP entries to every user port, so a later
    // member port already sees the full desired set with nothing to do; a per-port switch
    // (e.g. 88E6390/6393x) shows an empty map on each fresh port and must be programmed
    // individually. Detecting this from the mirrored state avoids relying on EEXIST.
    if !wasEmpty, apps.allSatisfy({ currentPCP.contains($0) }) {
      _ingressMappingIsGlobal = true
      return
    }

    let stale = currentPCP.filter { !apps.contains($0) }
    if !stale.isEmpty {
      try? await port._rtnl.remove(dcbApps: stale, socket: _nlLinkSocket)
    }

    let missing = apps.filter { !currentPCP.contains($0) }
    if !missing.isEmpty {
      do {
        try await port._rtnl.add(dcbApps: missing, socket: _nlLinkSocket)
      } catch Errno.fileExists {
        // Belt-and-braces: entries already mirrored from another port -> global map.
        _ingressMappingIsGlobal = true
      }
    }
  }

  func unconfigureIngressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) async throws {
    guard _ingressQueuePorts.contains(port.id) else { return }
    _ingressQueuePorts.remove(port.id)

    // On a global-map switch a delete is mirrored to every port, so other member ports still
    // rely on the shared map: only tear it down once the last member port has left. On a
    // per-port switch each port owns its entries and must be torn down individually.
    if _ingressMappingIsGlobal, !_ingressQueuePorts.isEmpty { return }

    let apps = try _ingressDCBApps(
      port: port,
      srClassPriorityMap: srClassPriorityMap,
      queues: queues,
      forceAvbCapable: forceAvbCapable
    )

    do {
      try await port._rtnl.remove(dcbApps: apps, socket: _nlLinkSocket)
    } catch Errno.noSuchFileOrDirectory {
      // Already gone (e.g. a delete mirrored from another port on a global-map switch).
    }
  }

  func adjustCreditBasedShaper(
    port: P,
    queue: UInt,
    idleSlope: Int,
    sendSlope: Int,
    hiCredit: Int,
    loCredit: Int
  ) async throws {
    guard let _nlQDiscHandle else {
      throw MSRPFailure(systemID: port.systemID, failureCode: .egressPortIsNotAvbCapable)
    }

    let removeShaper = hiCredit == 0 && loCredit == 0 && idleSlope == 0
    let parent = UInt32(_nlQDiscHandle) << 16 | UInt32(queue)

    do {
      if removeShaper {
        try await port._rtnl.remove(handle: 0, parent: parent, socket: _nlLinkSocket)
      } else {
        try await port._rtnl.add(
          handle: 0, // this allows the kernel to assign a handle
          parent: parent,
          offload: true,
          hiCredit: Int32(hiCredit),
          loCredit: Int32(loCredit),
          idleSlope: Int32(idleSlope),
          sendSlope: Int32(sendSlope),
          socket: _nlLinkSocket
        )
      }
    } catch {
      _logger.debug(
        "adjustCreditBasedShaper: bridge \(self) port \(port) parent \(parent) hiCredit \(hiCredit) loCredit \(loCredit) idleSlope \(idleSlope) sendSlope \(sendSlope) failed: \(error)"
      )
      throw error
    }
  }

  func getSRClassPriorityMap(port: P) async throws -> SRClassPriorityMap? {
    let qDiscs = try await _nlLinkSocket.getQDiscs(
      family: sa_family_t(AF_UNSPEC),
      interfaceIndex: port.id
    ).filter { $0.index == port.id }.collect()

    guard let qDisc = qDiscs.compactMap({ $0 as? RTNLMQPrioQDisc }).first,
          let _nlQDiscHandle,
          qDisc.handle >> 16 == _nlQDiscHandle
    else {
      return nil
    }
    return qDisc.srClassPriorityMap?.1
  }

  nonisolated var srClassPriorityMapNotifications: AnyAsyncSequence<
    SRClassPriorityMapNotification<P>
  > {
    _srClassPriorityMapStream.eraseToAnyAsyncSequence()
  }

  fileprivate func _getPtpPortProperties(for port: P) async throws -> PortPropertiesNP {
    if let portProperties = _portPropertiesCache[port.id] { return portProperties }
    let defaultDataSet = try await _pmc.getDefaultDataSet()
    for portNumber in 1...defaultDataSet.numberPorts {
      if let portProperties = try? await _pmc.getPortPropertiesNP(portNumber: portNumber),
         portProperties.interface.description == port.name
      {
        _portPropertiesCache[port.id] = portProperties
        return portProperties
      }
    }
    _portPropertiesCache[port.id] = nil
    throw PTP.Error.unknownPort
  }
}

fileprivate extension RTNLMQPrioQDisc {
  var srClassPriorityMap: (LinuxPort.ID, SRClassPriorityMap)? {
    guard let priorityMap else { return nil }

    var srClassPriorityMap = SRClassPriorityMap()

    for (up, tc) in priorityMap {
      guard let srClassID = tc.srClassID else { continue }
      let srClassPriority = _mapUPToSRClassPriority(up)
      srClassPriorityMap[srClassID] = srClassPriority
    }

    return (index, srClassPriorityMap)
  }

  convenience init(
    handle: UInt32,
    parent: UInt32,
    srClassPriorityMap: SRClassPriorityMap, // SR class to PCP map
    queues: [SRclassID: UInt], // SR class to Qdisc handle map
    legacyQueueCount: UInt16? = nil,
    legacyQueueOffset: UInt16? = nil
  ) throws {
    let priorityMap: [UInt8: UInt8] = Dictionary(
      uniqueKeysWithValues: srClassPriorityMap
        .map { srClass, srClassPriority in
          (_mapSRClassPriorityToUP(srClassPriority), srClass.tc)
        }
    )

    let count: [UInt16] = [legacyQueueCount ?? 2] + [UInt16](
      repeating: 1, // one queue per SR class
      count: srClassPriorityMap.count
    )
    var offset: [UInt16] = [legacyQueueOffset ?? 0] + [UInt16](
      repeating: 0, // actual value will be set below
      count: srClassPriorityMap.count
    )

    for srClass in srClassPriorityMap.keys {
      let tc = Int(srClass.tc)
      guard tc != 0, offset.indices.contains(tc), let queue = queues[srClass] else {
        continue
      }

      precondition(queue > 0 && queue <= UInt16.max)

      offset[tc] = UInt16(queue) - 1
    }

    try self.init(
      handle: handle,
      parent: parent,
      numTC: srClassPriorityMap.keys.count + 1, // typically 3 (0-2)
      priorityMap: priorityMap,
      hwOffload: true,
      count: count,
      offset: offset,
      mode: .dcb,
      shaper: .dcb
    )
  }
}

fileprivate extension UnsafeMutablePointer {
  func propertyBasePointer<Property>(to property: KeyPath<Pointee, Property>)
    -> UnsafeMutablePointer<Property>?
  {
    guard let offset = MemoryLayout<Pointee>.offset(of: property) else { return nil }
    return (UnsafeMutableRawPointer(self) + offset).assumingMemoryBound(to: Property.self)
  }
}

// map mstpd's CIST status onto the MRP-native STP types (this file is the only MSTP importer)
private extension MSTPPortRole {
  var stpPortRole: STPPortRole {
    switch self {
    case .disabled: .disabled
    case .root: .root
    case .designated: .designated
    case .alternate: .alternate
    case .backup: .backup
    case .master: .master
    }
  }
}

private extension MSTPPortState {
  var stpPortState: STPPortState {
    switch self {
    case .disabled: .disabled
    case .listening: .listening
    case .learning: .learning
    case .forwarding: .forwarding
    case .blocking: .blocking
    }
  }
}

private extension MSTPCISTPortStatus {
  var stpPortStatus: STPPortStatus {
    STPPortStatus(role: role.stpPortRole, state: state.stpPortState)
  }
}
#endif
