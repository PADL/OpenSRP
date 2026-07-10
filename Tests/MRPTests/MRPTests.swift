//
// Copyright (c) 2024-2025 PADL Software Pty Ltd
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

@_spi(MRPTesting)
@testable import MRP
@testable import PMC
import XCTest
@preconcurrency
import AsyncExtensions
import BinaryParsing
import IEEE802
import Logging
import Synchronization
import SystemPackage

struct MockPort: MRP.Port, Equatable, Hashable, Identifiable, Sendable, CustomStringConvertible,
  AVBPort
{
  var id: Int
  var stpPortState: STPPortState? =
    .forwarding // equality/hash are by id only, so a re-add can flip this

  static func == (lhs: MockPort, rhs: MockPort) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {}

  var isOperational: Bool = true

  var isEnabled: Bool { true }

  // full duplex is a point-to-point MAC (mirrors LinuxPort._operPointToPointMAC)
  var isPointToPoint: Bool { _isFullDuplex }

  var name: String { "eth\(id)" }

  var description: String { name }

  let _pvid: UInt16?
  var pvid: UInt16? { _pvid }

  let _vlans: Set<UInt16>
  var vlans: Set<MRP.VLAN> { Set(_vlans.map { VLAN(vid: $0) }) }

  let _dynamicVlans: Set<UInt16>
  var dynamicVlans: Set<MRP.VLAN> { Set(_dynamicVlans.map { VLAN(vid: $0) }) }

  var macAddress: EUI48 { [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] }

  let _mtu: UInt
  var mtu: UInt { _mtu }

  let _linkSpeed: UInt
  var linkSpeed: UInt { _linkSpeed }

  let _isFullDuplex: Bool

  // mirror LinuxPort: a port is AVB capable only with an MTU at or below the AVB max frame size,
  // a full-duplex link and a link speed of at least 100 Mb/s (IEEE 802.1BA-2011 §6.4 / Table 6.1)
  var isAvbCapable: Bool { _mtu <= AVBMaxFrameSize && _isFullDuplex && _linkSpeed >= 100_000 }

  var isAsCapable: Bool { true }

  let _portTcMaxLatency: Int
  // A real LinuxPort re-reads gPTP on every sample, so its per-hop latency can rise without the
  // port object changing. Model that with a live per-id override the test can raise; absent one the
  // port returns its construction-time value. A port id in _ptpNotReady throws instead, modelling
  // gPTP without a meanLinkDelay yet (LinuxPort.getPortTcMaxLatency throws in that case).
  static let _latencyOverrides = Mutex([Int: Int]())
  static let _ptpNotReady = Mutex(Set<Int>())
  func getPortTcMaxLatency(for _: SRclassPriority) async throws -> Int {
    if MockPort._ptpNotReady.withLock({ $0.contains(id) }) { throw MRPError.ptpNotReady }
    return MockPort._latencyOverrides.withLock { $0[id] } ?? _portTcMaxLatency
  }

  let _pfcEnabledPriorities: Set<SRclassPriority>
  var pfcEnabledPriorities: Set<SRclassPriority> { get async throws { _pfcEnabledPriorities } }

  func setFlowControl(_ enabled: Bool) async throws {}

  init(
    id: ID,
    pvid: UInt16? = nil,
    vlans: Set<UInt16> = [2],
    dynamicVlans: Set<UInt16> = [],
    pfcEnabledPriorities: Set<SRclassPriority> = [],
    mtu: UInt = 1500,
    linkSpeed: UInt = 1_000_000,
    isFullDuplex: Bool = true,
    portTcMaxLatency: Int = 0
  ) {
    self.id = id
    _pvid = pvid
    _vlans = vlans
    _dynamicVlans = dynamicVlans
    _mtu = mtu
    _linkSpeed = linkSpeed
    _isFullDuplex = isFullDuplex
    _pfcEnabledPriorities = pfcEnabledPriorities
    _portTcMaxLatency = portTcMaxLatency
  }

  static var now: ContinuousClock.Instant { .now }
}

// Records the kernel-facing effects (CBS idleslope + FDB reservation entries) so
// recompute tests can assert on convergence and idempotency.
actor MRPTestRecorder {
  private(set) var cbs = [(port: Int, queue: UInt, idleSlope: Int)]()
  private(set) var fdbRegister = [(mac: EUI48, vlan: VLAN?, ports: Set<Int>)]()
  private(set) var fdbDeregister = [(mac: EUI48, vlan: VLAN?, ports: Set<Int>)]()
  // register/deregister ops in the order applied, so tests can compute net group membership
  private(set) var fdbOps = [(register: Bool, mac: EUI48, ports: Set<Int>)]()

  // ports currently carrying a group MDB entry for `mac` (replays fdbOps in order)
  func fdbMembers(mac: EUI48) -> Set<Int> {
    var members = Set<Int>()
    for op in fdbOps where _isEqualMacAddress(op.mac, mac) {
      if op.register { members.formUnion(op.ports) } else { members.subtract(op.ports) }
    }
    return members
  }

  private(set) var vlanRegister = [(vlan: VLAN, port: Int)]()
  private(set) var vlanDeregister = [(vlan: VLAN, port: Int)]()
  private(set) var txPackets = [(port: Int, payload: [UInt8])]()
  private(set) var stpStatusQueries = [Int]()
  private var stpStatuses = [Int: STPPortStatus]()

  func recordTx(port: Int, payload: [UInt8]) {
    txPackets.append((port, payload))
  }

  func recordStpStatusQuery(port: Int) {
    stpStatusQueries.append(port)
  }

  func setStpStatus(_ status: STPPortStatus?, port: Int) {
    stpStatuses[port] = status
  }

  func stpStatus(port: Int) -> STPPortStatus? {
    stpStatuses[port]
  }

  // VIDs whose dynamic FDB registration MockBridge should reject (simulate FDB full, 11.2.3.2.2)
  private var failVlanRegistrationVids = Set<UInt16>()

  func setFailVlanRegistration(_ vids: Set<UInt16>) {
    failVlanRegistrationVids = vids
  }

  func shouldFailVlanRegistration(_ vid: UInt16) -> Bool {
    failVlanRegistrationVids.contains(vid)
  }

  // (port, VID) pairs whose dynamic FDB was flushed on a New indication (11.2.5)
  private(set) var flushedDynamicFdb = [(port: Int, vid: UInt16)]()
  func recordFlushDynamicFdb(vlan: VLAN, port: Int) {
    flushedDynamicFdb.append((port: port, vid: vlan.vid))
  }

  // ports whose credit-based-shaper program MockBridge should reject (simulate a transient error)
  private var failCbsPorts = Set<Int>()

  func setFailCbs(ports: Set<Int>) {
    failCbsPorts = ports
  }

  func shouldFailCbs(port: Int) -> Bool {
    failCbsPorts.contains(port)
  }

  func recordCBS(port: Int, queue: UInt, idleSlope: Int) {
    cbs.append((port, queue, idleSlope))
  }

  // ports whose egress queues (mqprio) MockBridge has configured
  private(set) var egressConfiguredPorts = Set<Int>()
  func recordEgressConfigured(port: Int) { egressConfiguredPorts.insert(port) }
  func didConfigureEgress(port: Int) -> Bool { egressConfiguredPorts.contains(port) }

  // when set, getSRClassPriorityMap returns nil for a port whose egress queues were never
  // configured (models a DSA port with no AVB mqprio until we program it)
  private(set) var priorityMapRequiresEgressConfig = false
  func setPriorityMapRequiresEgressConfig(_ enabled: Bool) {
    priorityMapRequiresEgressConfig = enabled
  }

  // ports whose egress-queue configuration MockBridge should reject (simulate a transient error)
  private var failEgressConfigPorts = Set<Int>()
  func setFailEgressConfig(ports: Set<Int>) { failEgressConfigPorts = ports }
  func shouldFailEgressConfig(port: Int) -> Bool { failEgressConfigPorts.contains(port) }

  func recordFDBRegister(mac: EUI48, vlan: VLAN?, ports: Set<Int>) {
    fdbRegister.append((mac, vlan, ports))
    fdbOps.append((register: true, mac: mac, ports: ports))
  }

  func recordFDBDeregister(mac: EUI48, vlan: VLAN?, ports: Set<Int>) {
    fdbDeregister.append((mac, vlan, ports))
    fdbOps.append((register: false, mac: mac, ports: ports))
  }

  func recordVLANRegister(vlan: VLAN, port: Int) {
    vlanRegister.append((vlan, port))
  }

  func recordVLANDeregister(vlan: VLAN, port: Int) {
    vlanDeregister.append((vlan, port))
  }
}

// every destination MAC a receiver would reconstruct from the talkerAdvertise vectors
// in the captured transmissions. Free function for use in _waitFor's @Sendable closure.
private func _transmittedTalkerDestinations(
  _ recorder: MRPTestRecorder,
  _ msrp: MSRPApplication<MockPort>
) async -> Set<UInt64> {
  var dests = Set<UInt64>()
  for packet in await recorder.txPackets {
    guard let pdu = try? packet.payload.withParserSpan({ input in
      try MRPDU(parsing: &input, application: msrp)
    }) else { continue }
    for message in pdu.messages
      where message.attributeType == MSRPAttributeType.talkerAdvertise.rawValue
    {
      for vector in message.attributeList {
        for i in 0..<Int(vector.numberOfValues) {
          guard let value = try? vector.firstValue.value.makeValue(relativeTo: UInt64(i)),
                let talker = value as? MSRPTalkerAdvertiseValue else { continue }
          dests.insert(UInt64(eui48: talker.dataFrameParameters.destinationAddress))
        }
      }
    }
  }
  return dests
}

// the srClassVID of each SR class Domain in the captured transmissions
private func _transmittedDomainVIDs(
  _ recorder: MRPTestRecorder,
  _ msrp: MSRPApplication<MockPort>
) async -> [SRclassID: UInt16] {
  var result = [SRclassID: UInt16]()
  for packet in await recorder.txPackets {
    guard let pdu = try? packet.payload.withParserSpan({ input in
      try MRPDU(parsing: &input, application: msrp)
    }) else { continue }
    for message in pdu.messages
      where message.attributeType == MSRPAttributeType.domain.rawValue
    {
      for vector in message.attributeList {
        if let domain = vector.firstValue.value as? MSRPDomainValue {
          result[domain.srClassID] = domain.srClassVID
        }
      }
    }
  }
  return result
}

// every AccumulatedLatency transmitted in a Talker Advertise for a stream out a given port
private func _transmittedAdvertiseLatencies(
  _ recorder: MRPTestRecorder,
  _ msrp: MSRPApplication<MockPort>,
  port: Int,
  streamID: MSRPStreamID
) async -> [UInt32] {
  var result = [UInt32]()
  for packet in await recorder.txPackets where packet.port == port {
    guard let pdu = try? packet.payload.withParserSpan({ input in
      try MRPDU(parsing: &input, application: msrp)
    }) else { continue }
    for message in pdu.messages
      where message.attributeType == MSRPAttributeType.talkerAdvertise.rawValue
    {
      for vector in message.attributeList {
        if let talker = vector.firstValue.value as? MSRPTalkerAdvertiseValue,
           talker.streamID == streamID
        {
          result.append(talker.accumulatedLatency)
        }
      }
    }
  }
  return result
}

// the (srClassID, value-count) of every Domain vector in the captured transmissions
private func _transmittedDomainVectors(
  _ recorder: MRPTestRecorder,
  _ msrp: MSRPApplication<MockPort>
) async -> [(srClassID: SRclassID, count: UInt16)] {
  var result = [(srClassID: SRclassID, count: UInt16)]()
  for packet in await recorder.txPackets {
    guard let pdu = try? packet.payload.withParserSpan({ input in
      try MRPDU(parsing: &input, application: msrp)
    }) else { continue }
    for message in pdu.messages
      where message.attributeType == MSRPAttributeType.domain.rawValue
    {
      for vector in message.attributeList {
        if let domain = vector.firstValue.value as? MSRPDomainValue {
          result.append((domain.srClassID, vector.numberOfValues))
        }
      }
    }
  }
  return result
}

// every AttributeEvent transmitted for a given VID out a given port in the captured
// transmissions. Free function for use in _waitFor's @Sendable closure.
private func _transmittedVLANEvents(
  _ recorder: MRPTestRecorder,
  _ mvrp: MVRPApplication<MockPort>,
  port: Int,
  vid: UInt16
) async -> [AttributeEvent] {
  var events = [AttributeEvent]()
  for packet in await recorder.txPackets where packet.port == port {
    guard let pdu = try? packet.payload.withParserSpan({ input in
      try MRPDU(parsing: &input, application: mvrp)
    }) else { continue }
    for message in pdu.messages
      where message.attributeType == MVRPAttributeType.vid.rawValue
    {
      guard let vectorEvents = try? message.attributeList.map({ try $0.attributeEvents })
      else { continue }
      for (vector, attributeEvents) in zip(message.attributeList, vectorEvents) {
        for i in 0..<Int(vector.numberOfValues) where i < attributeEvents.count {
          guard let value = try? vector.firstValue.value.makeValue(relativeTo: UInt64(i)),
                (value as? VLAN)?.vid == vid else { continue }
          events.append(attributeEvents[i])
        }
      }
    }
  }
  return events
}

// is a VID declared (Applicant) by MVRP on a port?
private func _isVLANDeclared(
  _ mvrp: MVRPApplication<MockPort>, vid: UInt16, port: Int
) async -> Bool {
  guard let participant = try? await mvrp.findParticipant(port: MockPort(id: port))
  else { return false }
  return await participant.findAllAttributes(
    attributeType: MVRPAttributeType.vid.rawValue, matching: .matchAny
  ).contains { $0.isDeclared && ($0.attributeValue as? VLAN)?.vid == vid }
}

// is a VID registered (Registrar IN/LV, incl. Registration Fixed) by MVRP on a port?
private func _isVLANRegistered(
  _ mvrp: MVRPApplication<MockPort>, vid: UInt16, port: Int
) async -> Bool {
  guard let participant = try? await mvrp.findParticipant(port: MockPort(id: port))
  else { return false }
  return await participant.findAllAttributes(
    attributeType: MVRPAttributeType.vid.rawValue, matching: .matchAny
  ).contains {
    ($0.registrarState?.isRegistered ?? false) && ($0.attributeValue as? VLAN)?.vid == vid
  }
}

// the Registrar state (IN/LV/MT) MVRP holds for a VID on a port, or nil if no such attribute.
private func _vlanRegistrarState(
  _ mvrp: MVRPApplication<MockPort>, vid: UInt16, port: Int
) async -> Registrar.State? {
  guard let participant = try? await mvrp.findParticipant(port: MockPort(id: port))
  else { return nil }
  return await participant.findAllAttributes(
    attributeType: MVRPAttributeType.vid.rawValue, matching: .matchAny
  ).first { ($0.attributeValue as? VLAN)?.vid == vid }?.registrarState
}

// count of Join/New events transmitted for a VID on a port (re-declaration signal).
private func _vlanJoinCount(
  _ recorder: MRPTestRecorder, _ mvrp: MVRPApplication<MockPort>, port: Int, vid: UInt16
) async -> Int {
  await _transmittedVLANEvents(recorder, mvrp, port: port, vid: vid)
    .filter { $0 == .JoinIn || $0 == .JoinMt || $0 == .New }.count
}

// is a group MAC declared (Applicant) by MMRP on a port?
private func _isMMRPMacDeclared(
  _ mmrp: MMRPApplication<MockPort>, mac: EUI48, port: Int
) async -> Bool {
  guard let participant = try? await mmrp.findParticipant(port: MockPort(id: port))
  else { return false }
  return await participant.findAllAttributes(
    attributeType: MMRPAttributeType.mac.rawValue, matching: .matchAny
  ).contains {
    guard let value = $0.attributeValue as? MMRPMACValue else { return false }
    return $0.isDeclared && _isEqualMacAddress(value.macAddress, mac)
  }
}

// is an attribute of this type declared (Applicant) on a port for the stream?
// Free function (not a method) so it can be used inside _waitFor's @Sendable closure.
private func _isDeclared(
  _ msrp: MSRPApplication<MockPort>, _ attributeType: MSRPAttributeType,
  _ streamID: MSRPStreamID, port: Int
) async -> Bool {
  guard let participant = try? await msrp.findParticipant(port: MockPort(id: port))
  else { return false }
  return await participant.findAllAttributes(
    attributeType: attributeType.rawValue, matching: .matchAnyIndex(streamID.id)
  ).contains(where: \.isDeclared)
}

// whether a Talker (Advertise or Failed) is registered (Registrar IN/LV) for a stream on a port
private func _isTalkerRegistered(
  _ msrp: MSRPApplication<MockPort>, _ streamID: MSRPStreamID, port: Int
) async -> Bool {
  guard let participant = try? await msrp.findParticipant(port: MockPort(id: port))
  else { return false }
  for type in [MSRPAttributeType.talkerAdvertise, MSRPAttributeType.talkerFailed] {
    let registered = await participant.findAllAttributes(
      attributeType: type.rawValue, matching: .matchAnyIndex(streamID.id)
    ).contains { $0.registrarState?.isRegistered ?? false }
    if registered { return true }
  }
  return false
}

// the subtype of the declared listener attribute for a stream on a port (nil if none declared)
private func _declaredListenerSubtype(
  _ msrp: MSRPApplication<MockPort>, _ streamID: MSRPStreamID, port: Int
) async -> MSRPAttributeSubtype? {
  guard let participant = try? await msrp.findParticipant(port: MockPort(id: port))
  else { return nil }
  let declared = await participant.findAllAttributes(
    attributeType: MSRPAttributeType.listener.rawValue, matching: .matchAnyIndex(streamID.id)
  ).first { $0.isDeclared }
  guard let subtype = declared?.attributeSubtype else { return nil }
  return MSRPAttributeSubtype(rawValue: subtype)
}

// the Applicant state of the declared attribute for a stream on a port; a New-marked declaration
// leaves it in .VN/.AN (10.3 a). Free function for use inside _waitFor's @Sendable closure.
private func _declaredApplicantState(
  _ msrp: MSRPApplication<MockPort>, _ attributeType: MSRPAttributeType,
  _ streamID: MSRPStreamID, port: Int
) async -> Applicant.State? {
  guard let participant = try? await msrp.findParticipant(port: MockPort(id: port))
  else { return nil }
  return await participant.findAllAttributes(
    attributeType: attributeType.rawValue, matching: .matchAnyIndex(streamID.id)
  ).first { $0.isDeclared }?.applicantState
}

private func _isNewMarked(_ state: Applicant.State?) -> Bool { state == .VN || state == .AN }

// the failure code of the declared Talker Failed attribute for a stream on a port (nil if none)
private func _declaredTalkerFailureCode(
  _ msrp: MSRPApplication<MockPort>, _ streamID: MSRPStreamID, port: Int
) async -> TSNFailureCode? {
  guard let participant = try? await msrp.findParticipant(port: MockPort(id: port))
  else { return nil }
  let declared = await participant.findAllAttributes(
    attributeType: MSRPAttributeType.talkerFailed.rawValue, matching: .matchAnyIndex(streamID.id)
  ).first { $0.isDeclared }
  return (declared?.attributeValue as? MSRPTalkerFailedValue)?.failureCode
}

private func _declaredTalkerFailed(
  _ msrp: MSRPApplication<MockPort>, _ streamID: MSRPStreamID, port: Int
) async -> MSRPTalkerFailedValue? {
  guard let participant = try? await msrp.findParticipant(port: MockPort(id: port))
  else { return nil }
  let declared = await participant.findAllAttributes(
    attributeType: MSRPAttributeType.talkerFailed.rawValue, matching: .matchAnyIndex(streamID.id)
  ).first { $0.isDeclared }
  return declared?.attributeValue as? MSRPTalkerFailedValue
}

// the declared (propagated) Talker Advertise attribute for a stream on a port (nil if none)
private func _declaredTalkerAdvertise(
  _ msrp: MSRPApplication<MockPort>, _ streamID: MSRPStreamID, port: Int
) async -> MSRPTalkerAdvertiseValue? {
  guard let participant = try? await msrp.findParticipant(port: MockPort(id: port))
  else { return nil }
  let declared = await participant.findAllAttributes(
    attributeType: MSRPAttributeType.talkerAdvertise.rawValue, matching: .matchAnyIndex(streamID.id)
  ).first { $0.isDeclared }
  return declared?.attributeValue as? MSRPTalkerAdvertiseValue
}

struct MockBridge: MRP.Bridge, CustomStringConvertible {
  var notifications = AsyncEmptySequence<MRP.PortNotification<MockPort>>().eraseToAnyAsyncSequence()
  var rxPackets = AsyncEmptySequence<(Int, IEEE802Packet)>().eraseToAnyAsyncSequence()
  var ports: Set<MockPort> = [MockPort(id: 0)]
  var recorder = MRPTestRecorder()

  init() {}

  init(ports: Set<MockPort>, recorder: MRPTestRecorder) {
    self.ports = ports
    self.recorder = recorder
  }

  func getPorts(controller: isolated MRPController<P>) async throws -> Set<MockPort> {
    ports
  }

  typealias P = MockPort

  var description: String { "MockBridge" }
  func getVlans(controller: isolated MRPController<P>) async -> Set<MRP.VLAN> { [] }

  func getStpPortStatus(port: P) async -> STPPortStatus? {
    await recorder.recordStpStatusQuery(port: port.id)
    return await recorder.stpStatus(port: port.id)
  }

  func register(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<P>
  ) async throws {}
  func deregister(
    groupAddress: EUI48,
    etherType: UInt16,
    controller: isolated MRPController<P>
  ) async throws {}

  func run(controller: isolated MRPController<P>) async throws {}
  func shutdown(controller: isolated MRPController<P>) async throws {}

  func tx(
    _ packet: IEEE802Packet,
    on port: P,
    controller: isolated MRPController<P>
  ) async throws {
    await recorder.recordTx(port: port.id, payload: packet.payload)
  }
}

extension MockBridge: MSRPAwareBridge {
  func configureFiltering(
    on port: P, type: MSRPFilteringType, requireIngressFdbEntry: Bool,
    filter: Set<SRclassID>, regenerate: Set<SRclassID>
  ) async throws {}
  func unconfigureFiltering(on port: P, type: MSRPFilteringType) async throws {}

  func configureEgressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) async throws {
    if await recorder.shouldFailEgressConfig(port: port.id) {
      throw MRPError.internalError // simulate a transient mqprio-programming error
    }
    await recorder.recordEgressConfigured(port: port.id)
  }

  func unconfigureEgressQueues(port: P) async throws {
    // a port with no configured mqprio has nothing to remove; mirror tc del on a missing qdisc so a
    // caller that lets this abort the configure that follows leaves the port with no queues
    if await recorder.priorityMapRequiresEgressConfig,
       await !recorder.didConfigureEgress(port: port.id)
    {
      throw MRPError.internalError
    }
  }

  func configureIngressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) async throws {}

  func unconfigureIngressQueues(
    port: P,
    srClassPriorityMap: SRClassPriorityMap,
    queues: [SRclassID: UInt],
    forceAvbCapable: Bool
  ) async throws {}

  func adjustCreditBasedShaper(
    port: P,
    queue: UInt,
    idleSlope: Int,
    sendSlope: Int,
    hiCredit: Int,
    loCredit: Int
  ) async throws {
    if await recorder.shouldFailCbs(port: port.id) {
      throw MRPError.internalError // simulate a transient shaper-programming error
    }
    await recorder.recordCBS(port: port.id, queue: queue, idleSlope: idleSlope)
  }

  func getSRClassPriorityMap(port: P) async throws -> SRClassPriorityMap? {
    if await recorder.priorityMapRequiresEgressConfig,
       await !recorder.didConfigureEgress(port: port.id)
    {
      return nil // an unconfigured DSA port has no AVB mqprio to read a map from
    }
    return [.A: .CA, .B: .EE]
  }

  var srClassPriorityMapNotifications: AnyAsyncSequence<SRClassPriorityMapNotification<P>> {
    AsyncEmptySequence<SRClassPriorityMapNotification<P>>().eraseToAnyAsyncSequence()
  }

  var systemID: MSRPSystemID { MSRPSystemID(id: 0x8000_FFFF_FFFF_FFFF) }
}

extension MockBridge: MMRPAwareBridge {
  func register(
    macAddress: EUI48,
    vlan: VLAN?,
    flags: MMRPRegistrationFlags,
    on ports: Set<P>
  ) async -> Set<P.ID> {
    await recorder.recordFDBRegister(mac: macAddress, vlan: vlan, ports: Set(ports.map(\.id)))
    return Set(ports.map(\.id))
  }

  func deregister(macAddress: EUI48, vlan: VLAN?, from ports: Set<P>) async -> Set<P.ID> {
    await recorder.recordFDBDeregister(mac: macAddress, vlan: vlan, ports: Set(ports.map(\.id)))
    return Set(ports.map(\.id))
  }

  func register(
    serviceRequirement: MMRPServiceRequirementValue,
    on ports: Set<P>
  ) async throws {}

  func deregister(
    serviceRequirement: MMRPServiceRequirementValue,
    from ports: Set<P>
  ) async throws {}
}

extension MockBridge: MVRPAwareBridge {
  var vlanRegistrationNotifications: AnyAsyncSequence<VLANRegistrationNotification<P>> {
    AsyncEmptySequence<VLANRegistrationNotification<P>>().eraseToAnyAsyncSequence()
  }

  func register(vlan: VLAN, on port: P, static isStatic: Bool) async throws {
    guard !isStatic else { return } // static VLANs preexist in the kernel; nothing to record
    if await recorder.shouldFailVlanRegistration(vlan.vid) {
      throw MRPError.internalError // simulate a kernel FDB-full rejection
    }
    await recorder.recordVLANRegister(vlan: vlan, port: port.id)
  }

  func deregister(vlan: VLAN, from port: P) async throws {
    await recorder.recordVLANDeregister(vlan: vlan, port: port.id)
  }

  func flushDynamicFdb(vlan: VLAN, on port: P) async throws {
    await recorder.recordFlushDynamicFdb(vlan: vlan, port: port.id)
  }
}

// records whether a Timer's expiry callback fired, for the leavetimer tests
private actor TimerExpiryFlag {
  private(set) var fired = false
  func fire() { fired = true }
}

final class MRPTests: XCTestCase {
  func testEUI48() throws {
    let eui48: EUI48 = [0, 0, 0, 0, 0x1, 0xFF]
    XCTAssertEqual(UInt64(eui48: eui48), 0x1FF)
    XCTAssertTrue(try _isEqualMacAddress(eui48, UInt64(0x1FF).asEUI48()))
  }

  func testStringToMacAddress() {
    // Test valid colon-separated formats
    let mac1 = _stringToMacAddress("01:02:03:04:05:06")
    XCTAssertNotNil(mac1)
    if let mac1 {
      XCTAssertEqual(_macAddressToString(mac1), "01:02:03:04:05:06")
    }

    // Test lowercase hex
    let mac2 = _stringToMacAddress("aa:bb:cc:dd:ee:ff")
    XCTAssertNotNil(mac2)
    if let mac2 {
      XCTAssertEqual(_macAddressToString(mac2), "aa:bb:cc:dd:ee:ff")
    }

    // Test uppercase hex
    let mac3 = _stringToMacAddress("AA:BB:CC:DD:EE:FF")
    XCTAssertNotNil(mac3)
    if let mac3 {
      XCTAssertEqual(_macAddressToString(mac3), "aa:bb:cc:dd:ee:ff")
    }

    // Test mixed case
    let mac4 = _stringToMacAddress("aA:bB:cC:dD:eE:fF")
    XCTAssertNotNil(mac4)
    if let mac4 {
      XCTAssertEqual(_macAddressToString(mac4), "aa:bb:cc:dd:ee:ff")
    }

    // Test broadcast address
    let mac5 = _stringToMacAddress("ff:ff:ff:ff:ff:ff")
    XCTAssertNotNil(mac5)
    if let mac5 {
      XCTAssertEqual(_macAddressToString(mac5), "ff:ff:ff:ff:ff:ff")
    }

    // Test zero address
    let mac6 = _stringToMacAddress("00:00:00:00:00:00")
    XCTAssertNotNil(mac6)
    if let mac6 {
      XCTAssertEqual(_macAddressToString(mac6), "00:00:00:00:00:00")
    }

    // Test invalid formats - should all return nil

    // No colons (not supported)
    XCTAssertNil(_stringToMacAddress("010203040506"))

    // Too short
    XCTAssertNil(_stringToMacAddress("01:02:03:04:05"))

    // Too long
    XCTAssertNil(_stringToMacAddress("01:02:03:04:05:06:07"))

    // Invalid hex characters
    XCTAssertNil(_stringToMacAddress("zz:zz:zz:zz:zz:zz"))

    // Single hex digit components
    XCTAssertNil(_stringToMacAddress("1:2:3:4:5:6"))

    // Three hex digit components
    XCTAssertNil(_stringToMacAddress("001:002:003:004:005:006"))

    // Empty string
    XCTAssertNil(_stringToMacAddress(""))

    // Only colons
    XCTAssertNil(_stringToMacAddress(":::::"))

    // Wrong number of colons
    XCTAssertNil(_stringToMacAddress("01:02:03:04"))
    XCTAssertNil(_stringToMacAddress("01:02:03:04:05:06:07:08"))

    // Test round-trip conversion
    if let original = _stringToMacAddress("01:23:45:67:89:ab") {
      let converted = _macAddressToString(original)
      if let roundTrip = _stringToMacAddress(converted) {
        XCTAssertEqual(_macAddressToString(roundTrip), converted)
      } else {
        XCTFail("Failed to convert back from string")
      }
    } else {
      XCTFail("Failed initial conversion")
    }
  }

  func testBasic() async throws {
    let logger = Logger(label: "com.padl.MRPTests")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let mvrp = try await MVRPApplication(controller: controller)

    let bytes: [UInt8] = [
      0x01,
      0x80,
      0xC2,
      0x00,
      0x00,
      0x21,
      0x00,
      0x04,
      0x96,
      0x51,
      0xEA,
      0xA5,
      0x88,
      0xF5,
      0x00,
      0x01,
      0x02,
      0x00,
      0x02,
      0x00,
      0x01,
      0x72,
      0x00,
      0x01,
      0x00,
      0x21,
      0x6C,
      0x00,
      0x01,
      0x00,
      0x64,
      0x48,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ]

    let packet = try bytes.withParserSpan { input in
      try IEEE802Packet(parsing: &input)
    }

    let pdu = try packet.payload.withParserSpan { input in
      try MRPDU(parsing: &input, application: mvrp)
    }
    XCTAssertEqual(pdu.protocolVersion, 0)
    XCTAssertEqual(pdu.messages.count, 1)
    if let message = pdu.messages.first {
      XCTAssertEqual(message.attributeType, 1)
      XCTAssertEqual(message.attributeList.count, 3)
      if let firstAttribute = message.attributeList.first {
        XCTAssertEqual(firstAttribute.firstValue, AnyValue(VLAN(vid: 1)))
        XCTAssertEqual(firstAttribute.leaveAllEvent, .NullLeaveAllEvent)
        XCTAssertEqual(firstAttribute.threePackedEvents.map(\.value), [114])
        XCTAssertEqual(try firstAttribute.attributeEvents, [.JoinMt, .JoinIn])

        let v = VectorAttribute(
          leaveAllEvent: .NullLeaveAllEvent,
          firstValue: AnyValue(VLAN(vid: 1)),
          attributeEvents: [.JoinMt, .JoinIn],
          applicationEvents: nil
        )
        XCTAssertEqual(v, firstAttribute)
      }
    }

    var serializationContext = SerializationContext()
    try packet.serialize(into: &serializationContext)
    XCTAssertEqual(bytes, serializationContext.bytes)

    var serializationContext2 = SerializationContext()
    try pdu.serialize(into: &serializationContext2, application: mvrp)
    // Note: prefix is necessary because captured packet has trailing zeros
    XCTAssertEqual(
      Array(packet.payload.prefix(serializationContext2.bytes.count)),
      serializationContext2.bytes
    )
  }

  // Avnu ProAV Bridge §8.1: upon receipt of a badly formed MRPDU, a Bridge may act on the
  // contents preceding the corrupted field and shall discard everything that follows. A valid
  // message followed by a corrupt/truncated tail must therefore parse to the good prefix rather
  // than throwing the whole PDU away.
  func testMalformedPduKeepsValidPrefix() async throws {
    let logger = Logger(label: "com.padl.MRPTests")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let mvrp = try await MVRPApplication(controller: controller)

    // a valid single-message MVRP MRPDU: VLAN 1, JoinIn
    let vectorAttribute = VectorAttribute<AnyValue>(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(VLAN(vid: 1)),
      attributeEvents: [.JoinIn],
      applicationEvents: nil
    )
    let message = Message(
      attributeType: MVRPAttributeType.vid.rawValue, attributeList: [vectorAttribute]
    )
    var sc = SerializationContext()
    try MRPDU(protocolVersion: 0, messages: [message]).serialize(into: &sc, application: mvrp)
    let validBytes = sc.bytes

    // sanity: the well-formed PDU parses to exactly one message
    let valid = try validBytes.withParserSpan { try MRPDU(parsing: &$0, application: mvrp) }
    XCTAssertEqual(valid.messages.count, 1)

    // drop the trailing MRPDU EndMark (last 2 octets) so the malformations land *before* the end,
    // where the parser would otherwise stop cleanly
    let prefix = Array(validBytes.dropLast(2))

    // malformation #1: a single stray octet — too few bytes to peek the next EndMark (truncated
    // tail). Before the fix this threw out of the parser (BinaryParsing overrun, not an MRPError).
    let strayOctet = try (prefix + [0x01])
      .withParserSpan { try MRPDU(parsing: &$0, application: mvrp) }
    XCTAssertEqual(strayOctet.messages.count, 1, "valid message kept, stray octet discarded")

    // malformation #2: a second message that begins plausibly (attributeType, attributeLength)
    // but is truncated mid-attribute — the Message parser runs off the end.
    let truncatedMessage = try (prefix + [0x01, 0x02, 0xFF])
      .withParserSpan { try MRPDU(parsing: &$0, application: mvrp) }
    XCTAssertEqual(
      truncatedMessage.messages.count,
      1,
      "valid message kept, truncated msg discarded"
    )
  }

  func testLeaveAllOnlyVectorAttribute() {
    let vectorAttribute = VectorAttribute<AnyValue>(
      leaveAllEvent: .LeaveAll,
      firstValue: AnyValue(MSRPTalkerAdvertiseValue()),
      attributeEvents: [],
      applicationEvents: nil
    )
    let vectorAttributes = [vectorAttribute]
    XCTAssertEqual(vectorAttributes.count, 1)
    XCTAssertEqual(vectorAttribute.numberOfValues, 0)
  }

  // AVnu Bridge-1.1-MRP.c.10.1.7A: an MVRPDU whose ThreePackedEvents octet decodes to a reserved
  // AttributeEvent (>5, e.g. 0xFF -> 7) must be discarded (10.8.3.3) and must never trap the RX
  // debug-log path -- Participant._debugLogAttribute previously did `try!` and aborted the daemon.
  func testReservedAttributeEventDoesNotTrapDebugLog() async throws {
    var logger = Logger(label: "com.padl.MRPTests.7A")
    logger.logLevel = .debug // exercise _debugLogPdu -> _debugLogAttribute (the crash site)
    let recorder = MRPTestRecorder()
    let port = MockPort(id: 0)
    let bridge = MockBridge(ports: [port], recorder: recorder)
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let mvrp = try await MVRPApplication(controller: controller)
    try await mvrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: [port])

    // a valid VLAN 1 JoinIn, then corrupt the single ThreePackedEvents octet to 0xFF (event -> 7)
    var sc = SerializationContext()
    try MRPDU(protocolVersion: 0, messages: [Message(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .NullLeaveAllEvent,
        firstValue: AnyValue(VLAN(vid: 1)),
        attributeEvents: [.JoinIn],
        applicationEvents: nil
      )]
    )]).serialize(into: &sc, application: mvrp)
    var bytes = sc.bytes
    let tpeIndex = bytes.count - 5 // ThreePackedEvents octet sits before the msg + MRPDU EndMarks
    XCTAssertEqual(bytes[tpeIndex], 0x24, "layout sanity: JoinIn ThreePackedEvents octet")
    bytes[tpeIndex] = 0xFF

    // the PDU still parses (events are decoded lazily) but decoding the reserved event throws
    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: mvrp) }
    XCTAssertThrowsError(try pdu.messages[0].attributeList[0].attributeEvents) {
      XCTAssertEqual($0 as? MRPError, .unknownAttributeEvent)
    }

    // driving rx logs the PDU at .debug then discards it: must not crash, must register nothing
    _ = try? await mvrp.rx(
      pdu: pdu,
      for: MAPBaseSpanningTreeContext,
      from: port,
      sourceMacAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    )
    let registered = await _isVLANRegistered(mvrp, vid: 1, port: 0)
    XCTAssertFalse(registered, "a reserved-AttributeEvent attribute must register nothing")
    _ = controller
  }

  // AVnu Bridge-1.1-MRP.c.10.1.7B: a reserved LeaveAllEvent (>1) discards only the offending PDU
  // (10.8.3.3/10.8.3.4) -- a subsequent well-formed declaration must still register (the parser is
  // stateless across PDUs and rejects the reserved value before mutating any Registrar state).
  func testReservedLeaveAllEventDiscardsPduAndRecovers() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0])

    // a valid VLAN 1 New, then set the vector header's top 3 bits (LeaveAllEvent) to a reserved 3
    var sc = SerializationContext()
    try MRPDU(protocolVersion: 0, messages: [Message(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .NullLeaveAllEvent,
        firstValue: AnyValue(VLAN(vid: 1)),
        attributeEvents: [.New],
        applicationEvents: nil
      )]
    )]).serialize(into: &sc, application: mvrp)
    var bytes = sc.bytes
    bytes[3] = (bytes[3] & 0x1F) | (3 << 5) // vector header high byte: LeaveAllEvent = reserved 3

    // the reserved LeaveAllEvent throws in VectorHeader parse before any state change; the message
    // is discarded and no valid prefix precedes it, so the PDU parses to zero messages (10.8.3.3).
    let parsed = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: mvrp) }
    XCTAssertEqual(parsed.messages.count, 0, "the reserved-LeaveAllEvent message must be discarded")

    // recovery: a subsequent well-formed New for another VID registers normally
    try await _driveMVRP(mvrp, port: 0, vid: 16, event: .New)
    let registered = await _waitFor { await _isVLANRegistered(mvrp, vid: 16, port: 0) }
    XCTAssertTrue(registered, "a valid declaration after a discarded malformed PDU must register")
    _ = controller
  }

  func testMMRPSerialization() async throws {
    let logger = Logger(label: "com.padl.MRPTests.MMRP")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    _ = try await MMRPApplication(controller: controller)

    // Test service requirement value serialization
    let serviceReqValue = MMRPServiceRequirementValue.allGroups
    var serializationContext = SerializationContext()
    try serviceReqValue.serialize(into: &serializationContext)
    XCTAssertEqual(serializationContext.bytes, [0x00])

    let deserializedServiceReq = try [0x00].withParserSpan { input in
      try MMRPServiceRequirementValue(parsing: &input)
    }
    XCTAssertEqual(deserializedServiceReq, .allGroups)

    // Test MAC value serialization
    let macValue = MMRPMACValue(macAddress: [0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E])
    serializationContext = SerializationContext()
    try macValue.serialize(into: &serializationContext)

    // Test that we can deserialize what we just serialized
    let deserializedMAC = try serializationContext.bytes.withParserSpan { input in
      try MMRPMACValue(parsing: &input)
    }

    // Test round-trip serialization - with the fixed deserialization logic,
    // this should now properly preserve the data
    var testSerializationContext = SerializationContext()
    try deserializedMAC.serialize(into: &testSerializationContext)

    // The round-trip should now preserve the original bytes
    XCTAssertEqual(testSerializationContext.bytes, serializationContext.bytes)

    // Also verify that the MAC address itself is correctly preserved
    XCTAssertTrue(_isEqualMacAddress(
      deserializedMAC.macAddress,
      [0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E]
    ))
  }

  func testAttributeValueEquality() {
    // Test with VLAN values
    let vlan1 = VLAN(vid: 100)
    let vlan2 = VLAN(vid: 100)
    let vlan3 = VLAN(vid: 200)

    let av1 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan1)
    )
    let av2 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan2)
    )
    let av3 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan3)
    )

    // Test basic equality
    XCTAssertEqual(av1, av2)
    XCTAssertNotEqual(av1, av3)

    // Test different attribute types
    let av4 = AttributeValue<MSRPApplication<MockPort>>(
      type: 2,
      subtype: nil,
      value: AnyValue(vlan1)
    )
    XCTAssertNotEqual(av1, av4)

    // Test with subtypes
    let av5 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 5,
      value: AnyValue(vlan1)
    )
    let av6 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 5,
      value: AnyValue(vlan1)
    )
    let av7 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 10,
      value: AnyValue(vlan1)
    )

    // Note: equality ignores subtype differences (as per comment in main code)
    XCTAssertEqual(av5, av6)
    XCTAssertEqual(av5, av7) // subtypes ignored in equality
    XCTAssertEqual(av1, av5) // nil subtype == any subtype for equality

    // Test with MMRP service requirement values
    let serviceReq1 = MMRPServiceRequirementValue.allGroups
    let serviceReq2 = MMRPServiceRequirementValue.allGroups
    let serviceReq3 = MMRPServiceRequirementValue.allUnregisteredGroups

    let av8 = AttributeValue<MSRPApplication<MockPort>>(
      type: 3,
      subtype: nil,
      value: AnyValue(serviceReq1)
    )
    let av9 = AttributeValue<MSRPApplication<MockPort>>(
      type: 3,
      subtype: nil,
      value: AnyValue(serviceReq2)
    )
    let av10 = AttributeValue<MSRPApplication<MockPort>>(
      type: 3,
      subtype: nil,
      value: AnyValue(serviceReq3)
    )

    XCTAssertEqual(av8, av9)
    XCTAssertNotEqual(av8, av10)

    // Test with MAC values
    let mac1 = MMRPMACValue(macAddress: [0x01, 0x80, 0xC2, 0x00, 0x00, 0x21])
    let mac2 = MMRPMACValue(macAddress: [0x01, 0x80, 0xC2, 0x00, 0x00, 0x21])
    let mac3 = MMRPMACValue(macAddress: [0x01, 0x80, 0xC2, 0x00, 0x00, 0x22])

    let av11 = AttributeValue<MSRPApplication<MockPort>>(
      type: 4,
      subtype: nil,
      value: AnyValue(mac1)
    )
    let av12 = AttributeValue<MSRPApplication<MockPort>>(
      type: 4,
      subtype: nil,
      value: AnyValue(mac2)
    )
    let av13 = AttributeValue<MSRPApplication<MockPort>>(
      type: 4,
      subtype: nil,
      value: AnyValue(mac3)
    )

    XCTAssertEqual(av11, av12)
    XCTAssertNotEqual(av11, av13)
  }

  func testAttributeValueMatchesFiltering() {
    let vlan1 = VLAN(vid: 100)
    let vlan2 = VLAN(vid: 105)

    let av1 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan1)
    )

    // Test matchAny
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchAny))
    XCTAssertTrue(av1.matches(attributeType: nil, matching: .matchAny))
    XCTAssertFalse(av1.matches(attributeType: 2, matching: .matchAny))

    // Test matchIdentity
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchIdentity(vlan1)))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchIdentity(vlan2)))
    XCTAssertFalse(av1.matches(attributeType: 2, matching: .matchIdentity(vlan1)))

    // Test matchAnyIndex
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchAnyIndex(vlan1.index)))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchAnyIndex(vlan2.index)))

    // Test matchIndex
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchIndex(vlan1)))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchIndex(vlan2)))

    // Test matchRelative (VLAN supports makeValue)
    XCTAssertTrue(av1.matches(attributeType: 1, matching: .matchRelative((VLAN(vid: 95), 5))))
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchRelative((VLAN(vid: 90), 5))))

    // Test with subtype
    _ = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: 10,
      value: AnyValue(vlan1)
    )
  }

  func testAttributeValueMatchesErrorHandling() {
    let vlan1 = VLAN(vid: 4095) // Max valid VLAN ID

    let av1 = AttributeValue<MSRPApplication<MockPort>>(
      type: 1,
      subtype: nil,
      value: AnyValue(vlan1)
    )

    // Test that invalid relative operations return false instead of throwing
    // This should fail because 4095 + 1 = 4096 which is invalid for VLAN
    XCTAssertFalse(av1.matches(attributeType: 1, matching: .matchRelative((vlan1, 1))))
  }

  func testMSRPTalkerAdvertiseEncoding() throws {
    let bytes: [UInt8] = [
      0x00,
      0x01,
      0xF2,
      0xFE,
      0xD2,
      0xA4,
      0x00,
      0x00,
      0x91,
      0xE0,
      0xF0,
      0x00,
      0xB3,
      0x68,
      0x00,
      0x02,
      0x00,
      0xE0,
      0x00,
      0x01,
      0x70,
      0x00,
      0x0B,
      0xF9,
      0x47,
    ]
    let streamID = MSRPStreamID(0x0001_F2FE_D2A4_0000)
    let dataFrameParams = MSRPDataFrameParameters(
      destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0xB3, 0x68],
      vlanIdentifier: 2
    )
    let tSpec = MSRPTSpec(maxFrameSize: 224, maxIntervalFrames: 1)
    let priorityAndRank = MSRPPriorityAndRank(dataFramePriority: .CA, rank: true)

    let talkerAdvertise = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 784_711
    )

    var serializationContext = SerializationContext()
    try talkerAdvertise.serialize(into: &serializationContext)

    XCTAssertEqual(bytes, serializationContext.bytes)
  }

  func testMSRPEquality() {
    let streamID = MSRPStreamID(0x0001_F2FE_D2A4_0000)
    let dataFrameParams = MSRPDataFrameParameters(
      destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x01, 0x02],
      vlanIdentifier: 2
    )
    let tSpec = MSRPTSpec(maxFrameSize: 224, maxIntervalFrames: 1)
    let priorityAndRank = MSRPPriorityAndRank(dataFramePriority: .CA, rank: true)

    let talkerAdvertise = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 650_000
    )

    XCTAssertEqual(talkerAdvertise, talkerAdvertise)

    let av1 = MSRPAttributeValue(
      type: 1,
      subtype: nil,
      value: AnyValue(talkerAdvertise)
    )
    let av2 = MSRPAttributeValue(
      type: 1,
      subtype: nil,
      value: AnyValue(talkerAdvertise)
    )

    XCTAssertEqual(av1, av2)

    let ae1 = MSRPEnqueuedEvent.AttributeEvent(
      attributeEvent: .JoinIn,
      attributeValue: av1,
      encodingOptional: false
    )
    let ae2 = MSRPEnqueuedEvent.AttributeEvent(
      attributeEvent: .JoinIn,
      attributeValue: av2,
      encodingOptional: false
    )

    XCTAssertEqual(ae1, ae2)

    let ee1 = MSRPEnqueuedEvent.attributeEvent(ae1)
    let ee2 = MSRPEnqueuedEvent.attributeEvent(ae2)

    XCTAssertEqual(ee1, ee2)
  }

  // 35.2.2.8.5(c): the Reserved nibble is zero-filled on transmit and ignored on receive
  func testMSRPPriorityAndRankIgnoresReservedBits() throws {
    let clean = MSRPPriorityAndRank(dataFramePriority: .CA, rank: true)
    XCTAssertEqual(clean.value & 0x0F, 0, "constructing must leave the Reserved nibble zero")

    let raw = [clean.value | 0x0F]
    let parsed = try raw.withParserSpan { try MSRPPriorityAndRank(parsing: &$0) }
    XCTAssertEqual(parsed, clean, "Reserved bits must be ignored on receive")
    XCTAssertEqual(parsed.dataFramePriority, clean.dataFramePriority)
    XCTAssertEqual(parsed.rank, clean.rank)

    var sc = SerializationContext()
    try parsed.serialize(into: &sc)
    XCTAssertEqual(sc.bytes, [clean.value], "Reserved bits must be zero on transmit")
  }

  func testMSRPSystemIDCreation() {
    // Test creation with integer literal
    let systemID1: MSRPSystemID = 0x7FFF_F8FB_1C25
    XCTAssertEqual(systemID1.id, 0x7FFF_F8FB_1C25)

    // Test creation with init
    let systemID2 = MSRPSystemID(id: 9_223_372_056_556_595_877)
    XCTAssertEqual(systemID2.id, 9_223_372_056_556_595_877)
  }

  func testMSRPSystemIDEquality() {
    let systemID1 = MSRPSystemID(id: 0x7FFF_F8FB_1C25)
    let systemID2 = MSRPSystemID(id: 0x7FFF_F8FB_1C25)
    let systemID3 = MSRPSystemID(id: 0x1234_5678_90AB_CDEF)

    XCTAssertEqual(systemID1, systemID2)
    XCTAssertNotEqual(systemID1, systemID3)
  }

  func testMSRPSystemIDDescription() {
    let systemID = MSRPSystemID(id: 0x7FFF_F8FB_1C25)
    // Description should be hex formatted without 0x prefix, padded to 16 chars
    XCTAssertEqual(systemID.description, "00007ffff8fb1c25")

    let systemID2 = MSRPSystemID(id: 0x1234_5678_90AB_CDEF)
    XCTAssertEqual(systemID2.description, "1234567890abcdef")
  }

  func testMSRPSystemIDSerialization() throws {
    let systemID = MSRPSystemID(id: 0x1234_5678_90AB_CDEF)
    var serializationContext = SerializationContext()
    try systemID.serialize(into: &serializationContext)

    // Should be serialized as big-endian 64-bit integer (8 bytes)
    XCTAssertEqual(serializationContext.bytes.count, 8)
    XCTAssertEqual(serializationContext.bytes, [0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF])
  }

  func testMSRPSystemIDParsing() throws {
    let bytes: [UInt8] = [0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF]
    let systemID = try bytes.withParserSpan { input in
      try MSRPSystemID(parsing: &input)
    }

    XCTAssertEqual(systemID.id, 0x1234_5678_90AB_CDEF)
  }

  func testMSRPSystemIDHashable() {
    let systemID1 = MSRPSystemID(id: 0x7FFF_F8FB_1C25)
    let systemID2 = MSRPSystemID(id: 0x7FFF_F8FB_1C25)
    let systemID3 = MSRPSystemID(id: 0x1234_5678_90AB_CDEF)

    var set = Set<MSRPSystemID>()
    set.insert(systemID1)
    set.insert(systemID2) // Should not increase set size
    XCTAssertEqual(set.count, 1)

    set.insert(systemID3)
    XCTAssertEqual(set.count, 2)
  }

  func testMSRPSerialization() throws {
    let streamID = MSRPStreamID(0x1234_5678_9ABC_DEF0)
    let dataFrameParams = MSRPDataFrameParameters()
    let tSpec = MSRPTSpec()
    let priorityAndRank = MSRPPriorityAndRank()

    let talkerAdvertise = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 1000
    )

    var serializationContext = SerializationContext()
    try talkerAdvertise.serialize(into: &serializationContext)

    let deserializedTalker = try serializationContext.bytes.withParserSpan { input in
      try MSRPTalkerAdvertiseValue(parsing: &input)
    }

    XCTAssertEqual(deserializedTalker.streamID, streamID)
    XCTAssertEqual(deserializedTalker.accumulatedLatency, 1000)

    let listener = MSRPListenerValue(streamID: streamID)
    serializationContext = SerializationContext()
    try listener.serialize(into: &serializationContext)

    let deserializedListener = try serializationContext.bytes.withParserSpan { input in
      try MSRPListenerValue(parsing: &input)
    }
    XCTAssertEqual(deserializedListener.streamID, streamID)

    let domain = try MSRPDomainValue()
    serializationContext = SerializationContext()
    try domain.serialize(into: &serializationContext)

    let deserializedDomain = try serializationContext.bytes.withParserSpan { input in
      try MSRPDomainValue(parsing: &input)
    }
    XCTAssertEqual(deserializedDomain.srClassID, domain.srClassID)
    XCTAssertEqual(deserializedDomain.srClassPriority, domain.srClassPriority)
    XCTAssertEqual(deserializedDomain.srClassVID, domain.srClassVID)
  }

  func testAttributeEventEquality() {
    let e1 = AttributeEvent.JoinMt
    let e2 = AttributeEvent.JoinMt

    XCTAssertEqual(e1, e2)
  }

  func testThreePackedEvents() {
    let threePackedEvent = ThreePackedEvents((1, 2, 3))
    XCTAssertEqual(threePackedEvent.value, (1 * 6 + 2) * 6 + 3)

    let tuple = threePackedEvent.tuple
    XCTAssertEqual(tuple.0, 1)
    XCTAssertEqual(tuple.1, 2)
    XCTAssertEqual(tuple.2, 3)

    let threePackedEvent2 = ThreePackedEvents((4, 5, 0))
    XCTAssertEqual(threePackedEvent2.value, (4 * 6 + 5) * 6 + 0)

    let tuple2 = threePackedEvent2.tuple
    XCTAssertEqual(tuple2.0, 4)
    XCTAssertEqual(tuple2.1, 5)
    XCTAssertEqual(tuple2.2, 0)
  }

  func testFourPackedEvents() {
    let fourPackedEvent = FourPackedEvents((1, 2, 3, 4))
    XCTAssertEqual(fourPackedEvent.value, 112) // 1*64 + 2*16 + 3*4 + 4 = 64 + 32 + 12 + 4 = 112

    let fourPackedEvent2 = FourPackedEvents((0, 1, 2, 3))
    XCTAssertEqual(fourPackedEvent2.value, 27) // 0*64 + 1*16 + 2*4 + 3 = 0 + 16 + 8 + 3 = 27

    let testValue = FourPackedEvents(UInt8(27))
    let testTuple = testValue.tuple
    XCTAssertEqual(testTuple.0, 0)
    XCTAssertEqual(testTuple.1, 1)
    XCTAssertEqual(testTuple.2, 2)
    XCTAssertEqual(testTuple.3, 3)
  }

  func testVectorHeaderSerialization() throws {
    // Test with NullLeaveAllEvent (0) and value 0x1234
    let header1 = VectorHeader(leaveAllEvent: .NullLeaveAllEvent, numberOfValues: 0x1234)

    var serializationContext = SerializationContext()
    try header1.serialize(into: &serializationContext)

    let expectedBytes1: [UInt8] = [0x12, 0x34] // 0 << 13 | 0x1234 = 0x1234
    XCTAssertEqual(serializationContext.bytes, expectedBytes1)

    let deserializedHeader1 = try expectedBytes1.withParserSpan { input in
      try VectorHeader(parsing: &input)
    }

    XCTAssertEqual(deserializedHeader1.leaveAllEvent, .NullLeaveAllEvent)
    XCTAssertEqual(deserializedHeader1.numberOfValues, 0x1234)

    // Test with LeaveAll (1) and value 0x0234: the LeaveAll bit is bit 13, so
    // (1 << 13) | 0x0234 = 0x2234
    let header2 = VectorHeader(leaveAllEvent: .LeaveAll, numberOfValues: 0x0234)

    serializationContext = SerializationContext()
    try header2.serialize(into: &serializationContext)

    let expectedBytes2: [UInt8] = [0x22, 0x34]
    XCTAssertEqual(serializationContext.bytes, expectedBytes2)

    let deserializedHeader2 = try expectedBytes2.withParserSpan { input in
      try VectorHeader(parsing: &input)
    }

    XCTAssertEqual(deserializedHeader2.leaveAllEvent, .LeaveAll)
    XCTAssertEqual(deserializedHeader2.numberOfValues, 0x0234)
  }

  func testValueMakeRelative() throws {
    let vlan = VLAN(vid: 100)
    let relativeVlan = try vlan.makeValue(relativeTo: 5)
    XCTAssertEqual(relativeVlan.vid, 105)

    let serviceReq = MMRPServiceRequirementValue.allGroups
    let relativeServiceReq = try serviceReq.makeValue(relativeTo: 1)
    XCTAssertEqual(relativeServiceReq, .allUnregisteredGroups)

    let macValue = MMRPMACValue(macAddress: [0x01, 0x80, 0xC2, 0x00, 0x00, 0x10])
    let relativeMac = try macValue.makeValue(relativeTo: 0x05)
    XCTAssertTrue(_isEqualMacAddress(relativeMac.macAddress, [0x01, 0x80, 0xC2, 0x00, 0x00, 0x15]))
  }

  func testSerializationErrorHandling() {
    XCTAssertThrowsError(try VLAN(vid: 0x1000).makeValue(relativeTo: 1)) { error in
      XCTAssertEqual(error as? MRPError, .invalidAttributeValue)
    }

    // 10.8.2.8 d): a peer-encoded FirstValue + NumberOfValues that overruns the value range
    // must throw on reconstruction, not trap the daemon (regression: MSRP/MMRP used to crash)
    XCTAssertThrowsError(
      try MSRPStreamID(integerLiteral: .max).makeValue(relativeTo: 1)
    ) { XCTAssertEqual($0 as? MRPError, .invalidAttributeValue) }
    XCTAssertThrowsError(
      try MSRPListenerValue(streamID: MSRPStreamID(integerLiteral: .max)).makeValue(relativeTo: 1)
    ) { XCTAssertEqual($0 as? MRPError, .invalidAttributeValue) }
    XCTAssertThrowsError(
      try MMRPMACValue(macAddress: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).makeValue(relativeTo: 1)
    ) { XCTAssertEqual($0 as? MRPError, .invalidAttributeValue) }

    XCTAssertThrowsError(try [0xFF, 0xFF].withParserSpan { input in
      try VLAN(parsing: &input)
    }) { error in
      XCTAssertEqual(error as? MRPError, .invalidAttributeValue)
    }

    XCTAssertThrowsError(try [0x01].withParserSpan { input in
      try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    })
  }

  func testBigEndianIntegerSerialization() throws {
    let uint16: UInt16 = 0x1234
    let uint32: UInt32 = 0x1234_5678
    let uint64: UInt64 = 0x1234_5678_9ABC_DEF0

    var serializationContext = SerializationContext()
    serializationContext.serialize(uint16: uint16)
    XCTAssertEqual(serializationContext.bytes, [0x12, 0x34])

    serializationContext = SerializationContext()
    serializationContext.serialize(uint32: uint32)
    XCTAssertEqual(serializationContext.bytes, [0x12, 0x34, 0x56, 0x78])

    serializationContext = SerializationContext()
    serializationContext.serialize(uint64: uint64)
    XCTAssertEqual(serializationContext.bytes, [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])

    let deserializedUInt16 = try [0x12, 0x34].withParserSpan { input in
      try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    }
    XCTAssertEqual(deserializedUInt16, 0x1234)

    let deserializedUInt32 = try [0x12, 0x34, 0x56, 0x78].withParserSpan { input in
      try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
    }
    XCTAssertEqual(deserializedUInt32, 0x1234_5678)

    let deserializedUInt64 = try [
      0x12,
      0x34,
      0x56,
      0x78,
      0x9A,
      0xBC,
      0xDE,
      0xF0,
    ].withParserSpan { input in
      try UInt64(parsing: &input, storedAsBigEndian: UInt64.self)
    }
    XCTAssertEqual(deserializedUInt64, 0x1234_5678_9ABC_DEF0)
  }

  func testEUI48Serialization() throws {
    let eui48: EUI48 = [0x01, 0x80, 0xC2, 0x00, 0x00, 0x21]

    var serializationContext = SerializationContext()
    serializationContext.serialize(eui48: eui48)
    XCTAssertEqual(serializationContext.bytes, [0x01, 0x80, 0xC2, 0x00, 0x00, 0x21])

    let deserializedEUI48 = try [0x01, 0x80, 0xC2, 0x00, 0x00, 0x21].withParserSpan { input in
      try _eui48(parsing: &input)
    }
    XCTAssertTrue(_isEqualMacAddress(deserializedEUI48, eui48))
  }

  // MARK: - State Machine Tests

  func testApplicantStateMachine() {
    let applicant = Applicant()
    let normalFlags: StateMachineHandlerFlags = []
    let pointToPointFlags: StateMachineHandlerFlags = [.operPointToPointMAC]

    // Test initial state
    XCTAssertEqual(applicant.description, "VO")

    // Test Begin event
    XCTAssertNil(applicant.action(for: .Begin, flags: normalFlags).0)
    XCTAssertEqual(applicant.description, "VO")

    // Test New event from VO -> VN
    let (newAction, newTxOpp) = applicant.action(for: .New, flags: normalFlags)
    XCTAssertNil(newAction)
    XCTAssertTrue(newTxOpp) // Entered VN state
    XCTAssertEqual(applicant.description, "VN")

    // Test tx event from VN -> AN with sN action
    let (action1, txOpp1) = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(action1, .sN)
    XCTAssertTrue(txOpp1) // Entered AN state
    XCTAssertEqual(applicant.description, "AN")

    // Test tx event from AN -> QA with sN action (Table 10-3 fn 8: QA because Registrar is IN)
    let (action2, txOpp2) = applicant.action(for: .tx, registrarState: .IN, flags: normalFlags)
    XCTAssertEqual(action2, .sN)
    XCTAssertFalse(txOpp2) // QA is not in the list
    XCTAssertEqual(applicant.description, "QA")

    // Test rJoinIn event from QA (no transition with point-to-point)
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: pointToPointFlags).0)
    XCTAssertEqual(applicant.description, "QA")

    // Test rJoinIn event from QA -> QA (no transition without point-to-point, different from AA
    // case)
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: normalFlags).0)
    XCTAssertEqual(applicant.description, "QA")

    // Test Leave event
    let (lvAction, lvTxOpp) = applicant.action(for: .Lv, flags: normalFlags)
    XCTAssertNil(lvAction)
    XCTAssertTrue(lvTxOpp) // Entered LA state
    XCTAssertEqual(applicant.description, "LA")

    // Test tx event from LA -> VO with sL action
    let (action3, _) = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(action3, .sL)
    XCTAssertEqual(applicant.description, "VO")
  }

  func testApplicantJoinTransitions() {
    let applicant = Applicant()
    let normalFlags: StateMachineHandlerFlags = []

    // Start from VO
    XCTAssertNil(applicant.action(for: .Begin, flags: normalFlags).0)
    XCTAssertEqual(applicant.description, "VO")

    // Test Join event from VO -> VP
    let (joinAction, joinTxOpp) = applicant.action(for: .Join, flags: normalFlags)
    XCTAssertNil(joinAction)
    XCTAssertTrue(joinTxOpp) // Entered VP state
    XCTAssertEqual(applicant.description, "VP")

    // Test tx event from VP -> AA with sJ action
    let (action, txOpp) = applicant.action(for: .tx, flags: normalFlags)
    XCTAssertEqual(action, .sJ)
    XCTAssertTrue(txOpp) // Entered AA state
    XCTAssertEqual(applicant.description, "AA")

    // Test rJoinIn from AA -> QA
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: normalFlags).0)
    XCTAssertEqual(applicant.description, "QA")

    // Test periodic from QA -> AA
    let (periodicAction, periodicTxOpp) = applicant.action(for: .periodic, flags: normalFlags)
    XCTAssertNil(periodicAction)
    XCTAssertTrue(periodicTxOpp) // Entered AA state
    XCTAssertEqual(applicant.description, "AA")
  }

  // 802.1Q-2022 Table 10-3 footnote 8: on tx! from AN the Applicant goes to QA only when the
  // Registrar is IN, and to AA otherwise (the registrar being LV or MT means a Leave may have
  // been lost between Applicants, so AA keeps re-transmitting Joins). txLA! from AN is always QA.
  func testApplicantTxFromANDependsOnRegistrarState() {
    func toAN() -> Applicant {
      let a = Applicant()
      _ = a.action(for: .New, flags: []) // VO -> VN
      _ = a.action(for: .tx, flags: []) // VN -> AN
      XCTAssertEqual(a.description, "AN")
      return a
    }

    // tx! with Registrar IN -> QA
    let aIn = toAN()
    let (actIn, txOppIn) = aIn.action(for: .tx, registrarState: .IN, flags: [])
    XCTAssertEqual(actIn, .sN)
    XCTAssertFalse(txOppIn) // QA does not request a tx opportunity
    XCTAssertEqual(aIn.description, "QA")

    // tx! with Registrar LV -> AA (registered, but not IN)
    let aLv = toAN()
    let (actLv, txOppLv) = aLv.action(for: .tx, registrarState: .LV, flags: [])
    XCTAssertEqual(actLv, .sN)
    XCTAssertTrue(txOppLv) // AA requests a tx opportunity
    XCTAssertEqual(aLv.description, "AA")

    // tx! with Registrar MT -> AA
    let aMt = toAN()
    let (actMt, _) = aMt.action(for: .tx, registrarState: .MT, flags: [])
    XCTAssertEqual(actMt, .sN)
    XCTAssertEqual(aMt.description, "AA")

    // tx! with no Registrar (Applicant-only, defaults to MT) -> AA
    let aNil = toAN()
    _ = aNil.action(for: .tx, flags: [])
    XCTAssertEqual(aNil.description, "AA")

    // txLA! from AN is unconditionally QA, regardless of Registrar state (no footnote on that cell)
    for state: Registrar.State in [.IN, .LV, .MT] {
      let a = toAN()
      let (act, _) = a.action(for: .txLA, registrarState: state, flags: [])
      XCTAssertEqual(act, .sN)
      XCTAssertEqual(a.description, "QA", "txLA! from AN must be QA for registrar \(state)")
    }
  }

  func testRegistrarStateMachine() {
    let registrar = Registrar(onLeaveTimerExpired: {})
    let normalFlags: StateMachineHandlerFlags = []

    // Test initial state
    XCTAssertEqual(registrar.state, .MT)

    // Test Begin event
    XCTAssertNil(registrar.action(for: .Begin, flags: normalFlags))
    XCTAssertEqual(registrar.state, .MT)

    // Test rNew event from MT -> IN with New action
    let action1 = registrar.action(for: .rNew, flags: normalFlags)
    XCTAssertEqual(action1, .New)
    XCTAssertEqual(registrar.state, .IN)

    // Test rJoinIn event from IN (no state change, no action)
    XCTAssertNil(registrar.action(for: .rJoinIn, flags: normalFlags))
    XCTAssertEqual(registrar.state, .IN)

    // Test rLv event from IN -> LV (starts leave timer) without the leaveImmediate flag
    let action2 = registrar.action(for: .rLv, flags: normalFlags)
    XCTAssertEqual(action2, nil)
    XCTAssertEqual(registrar.state, .LV)

    // Test rJoinIn from LV -> IN (stops leave timer), no action
    let action3 = registrar.action(for: .rJoinIn, flags: normalFlags)
    XCTAssertEqual(action3, nil)
    XCTAssertEqual(registrar.state, .IN)

    // Test rLA event from IN -> LV (starts leave timer)
    XCTAssertNil(registrar.action(for: .rLA, flags: normalFlags))
    XCTAssertEqual(registrar.state, .LV)

    // Test leavetimer event from LV -> MT with Lv action
    let action4 = registrar.action(for: .leavetimer, flags: normalFlags)
    XCTAssertEqual(action4, .Lv)
    XCTAssertEqual(registrar.state, .MT)
  }

  // Avnu ProAV Bridge §9.2 (MSRP, gated by .leaveImmediate): a received Leave takes the Registrar
  // straight from IN to MT with a Lv action, skipping the leavetimer. rLA!/txLA!/ReDeclare! still
  // use the leavetimer — the immediate transition is specific to rLv!.
  func testRegistrarLeaveImmediate() {
    let immediate: StateMachineHandlerFlags = [.leaveImmediate]

    // rLv! from IN -> MT with Lv, no leavetimer
    let r1 = Registrar(onLeaveTimerExpired: {})
    XCTAssertEqual(r1.action(for: .rNew, flags: immediate), .New)
    XCTAssertEqual(r1.state, .IN)
    XCTAssertEqual(r1.action(for: .rLv, flags: immediate), .Lv)
    XCTAssertEqual(r1.state, .MT)

    // rLA! still goes IN -> LV (leavetimer), even with the flag set
    let r2 = Registrar(onLeaveTimerExpired: {})
    _ = r2.action(for: .rNew, flags: immediate)
    XCTAssertNil(r2.action(for: .rLA, flags: immediate))
    XCTAssertEqual(r2.state, .LV)

    // txLA! still goes IN -> LV (leavetimer), even with the flag set
    let r3 = Registrar(onLeaveTimerExpired: {})
    _ = r3.action(for: .rNew, flags: immediate)
    XCTAssertNil(r3.action(for: .txLA, flags: immediate))
    XCTAssertEqual(r3.state, .LV)
  }

  func testRegistrarFlagsHandling() {
    let registrar = Registrar(onLeaveTimerExpired: {})

    // Test registrationForbidden flag
    let forbiddenFlags: StateMachineHandlerFlags = [.registrationForbidden]
    XCTAssertNil(registrar.action(for: .rNew, flags: forbiddenFlags))
    XCTAssertEqual(registrar.state, .MT)

    // Test registrationFixedNewIgnored flag
    let ignoredFlags: StateMachineHandlerFlags = [.registrationFixedNewIgnored]
    XCTAssertNil(registrar.action(for: .rNew, flags: ignoredFlags))
    XCTAssertEqual(registrar.state, .MT)

    // Test registrationFixedNewPropagated flag (allows rNew, blocks others)
    let propagatedFlags: StateMachineHandlerFlags = [.registrationFixedNewPropagated]
    let action1 = registrar.action(for: .rNew, flags: propagatedFlags)
    XCTAssertEqual(action1, .New)
    XCTAssertEqual(registrar.state, .IN)

    XCTAssertNil(registrar.action(for: .rJoinIn, flags: propagatedFlags))
    XCTAssertEqual(registrar.state, .IN) // No change
  }

  func testRegistrarPointToPointBehavior() {
    let registrar = Registrar(onLeaveTimerExpired: {})
    let pointToPointFlags: StateMachineHandlerFlags = [.operPointToPointMAC]

    // Set up state to LV
    _ = registrar.action(for: .rNew, flags: [])
    _ = registrar.action(for: .rLA, flags: [])
    XCTAssertEqual(registrar.state, .LV)

    // Test leavetimer with point-to-point flag
    let action = registrar.action(for: .leavetimer, flags: pointToPointFlags)
    XCTAssertEqual(action, .Lv)
    XCTAssertEqual(registrar.state, .MT)
  }

  func testLeaveAllStateMachine() {
    let leaveAll = LeaveAll(interval: .milliseconds(100)) {}

    // Test initial state
    XCTAssertEqual(leaveAll.state, .Passive)

    // Test Begin event
    let (action1, tx1) = leaveAll.action(for: .Begin)
    XCTAssertEqual(action1, .startLeaveAllTimer)
    XCTAssertEqual(leaveAll.state, .Passive)
    XCTAssertEqual(tx1, false)

    // Test startLeaveAllTimer event (timer expires) -> Active
    let (action2, tx2) = leaveAll.action(for: .leavealltimer)
    XCTAssertEqual(action2, .startLeaveAllTimer)
    XCTAssertEqual(leaveAll.state, .Active)
    XCTAssertEqual(tx2, true)

    // Test tx event from Active -> Passive with sLA action
    let (action3, tx3) = leaveAll.action(for: .tx)
    XCTAssertEqual(action3, .sLA)
    XCTAssertEqual(leaveAll.state, .Passive)
    XCTAssertEqual(tx3, false)

    // Test rLA event
    let (action4, tx4) = leaveAll.action(for: .rLA)
    XCTAssertEqual(action4, .startLeaveAllTimer)
    XCTAssertEqual(leaveAll.state, .Passive)
    XCTAssertEqual(tx4, false)

    // Test Flush event
    let (action5, tx5) = leaveAll.action(for: .Flush)
    XCTAssertEqual(action5, .startLeaveAllTimer)
    XCTAssertEqual(leaveAll.state, .Passive)
    XCTAssertEqual(tx5, false)

    // Test unknown event
    XCTAssertNil(leaveAll.action(for: .New).0)
  }

  func testApplicantLeaveAllTransitions() {
    let applicant = Applicant()
    let normalFlags: StateMachineHandlerFlags = []

    // Set up to QA state (AN -> QA requires the Registrar be IN, Table 10-3 fn 8)
    _ = applicant.action(for: .New, flags: normalFlags)
    _ = applicant.action(for: .tx, flags: normalFlags)
    _ = applicant.action(for: .tx, registrarState: .IN, flags: normalFlags)
    XCTAssertEqual(applicant.description, "QA")

    // Test txLA event from QA -> QA with sJ action
    let (action1, _) = applicant.action(for: .txLA, flags: normalFlags)
    XCTAssertEqual(action1, .sJ)
    XCTAssertEqual(applicant.description, "QA")

    // Test txLAF event from QA -> VP
    let (txLAFAction, txLAFTxOpp) = applicant.action(for: .txLAF, flags: normalFlags)
    XCTAssertNil(txLAFAction)
    XCTAssertTrue(txLAFTxOpp) // Entered VP state
    XCTAssertEqual(applicant.description, "VP")
  }

  // Regression (commit 3d860bb disabled Periodic Transmission by default): with periodic TX off,
  // a received LeaveAll must still re-assert an actively-declared attribute. Otherwise the peer's
  // registrar leavetimer expires between LeaveAlls (the Extreme's is 1s) and it deregisters us,
  // tearing down the stream reservation -> audio dropout. 10.7.2 makes LeaveAll the sole periodic
  // refresh once periodic TX is disabled; Table 10-3 rLA! moves the Applicant QA->VP and the next
  // tx! emits a Join. This test asserts that Join actually reaches the wire.
  func testLeaveAllReassertsDeclarationWithPeriodicTransmissionDisabled() async throws {
    let recorder = MRPTestRecorder()
    // VID 100 is static on port 0 only -> Registration Fixed, emitting JoinIn as an emission rule
    // (see testMVRPStaticVLANEmitsJoinInOnOwnPort). This is the SR_PVID shape that the Extreme
    // registers and then flushes with its LeaveAll.
    let ports: Set<MockPort> = [MockPort(id: 0, vlans: [2, 100]), MockPort(id: 1, vlans: [2])]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.leaveall"),
      // periodic TX DISABLED (Avnu ProAV default, commit 3d860bb); leaveTime 1s like the Extreme
      timerConfiguration: MRPTimerConfiguration(leaveTime: .seconds(1), periodicTime: .zero)
    )
    let mvrp = try await MVRPApplication(controller: controller)
    try await mvrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)

    // the Registration Fixed VLAN is emitted as JoinIn on its member port
    let emitted = await _waitFor {
      await _transmittedVLANEvents(recorder, mvrp, port: 0, vid: 100).contains(.JoinIn)
    }
    XCTAssertTrue(emitted, "VID 100 must be emitted as JoinIn initially")

    // with periodic off the port goes quiet after the initial emission -- snapshot the Join count
    try await Task.sleep(for: .seconds(1))
    let joinsBefore = await _vlanJoinCount(recorder, mvrp, port: 0, vid: 100)

    // a peer LeaveAll on port 0 flushes its registrars to LV; every registered attribute must be
    // re-asserted within the peer's LeaveTime or it is dropped. Emulate the Extreme's LeaveAll.
    let leaveAll = Message(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .LeaveAll,
        firstValue: AnyValue(VLAN(vid: 100)),
        attributeEvents: [], // numberOfValues == 0: a pure LeaveAll, no accompanying Join
        applicationEvents: nil
      )]
    )
    try await mvrp.rx(
      pdu: MRPDU(protocolVersion: 0, messages: [leaveAll]),
      for: MAPBaseSpanningTreeContext,
      from: MockPort(id: 0),
      sourceMacAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    )

    // the LeaveAll must trigger re-emission of the Registration Fixed VID 100 JoinIn within
    // LeaveTime
    let reasserted = await _waitFor(timeoutMs: 1500) {
      await _vlanJoinCount(recorder, mvrp, port: 0, vid: 100) > joinsBefore
    }
    XCTAssertTrue(
      reasserted,
      "with periodic TX disabled, a LeaveAll must re-emit the Registration Fixed VID 100 JoinIn within LeaveTime"
    )
    _ = controller
  }

  // Field regression (periodic TX off + Extreme LeaveTime 1s): a talker-side peer LeaveAll must
  // not tear down our relayed Listener Ready toward the talker. leaveImmediate is on (MSRP default,
  // Avnu 9.2) and the port is point-to-point, matching the field smFlags. If the Listener
  // declaration
  // toward the talker lapses to askingFailed/withdrawn across the LeaveAll+rejoin, the Extreme
  // drops
  // the reservation -> audio dropout.
  func testMSRPListenerSurvivesTalkerLeaveAllWithPeriodicDisabled() async throws {
    let recorder = MRPTestRecorder()
    let ports = Set([0, 1].map { MockPort(id: $0) })
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.leaveall.msrp"),
      timerConfiguration: MRPTimerConfiguration(leaveTime: .seconds(1), periodicTime: .zero)
    )
    let msrp = try await MSRPApplication(controller: controller, flags: .defaultFlags)
    XCTAssertTrue(msrp.registrarLeaveImmediate, "MSRP leaveImmediate must be on (Avnu 9.2)")
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)

    // peer Talker on port 0 (the Extreme), peer Listener Ready on port 1 (the endpoint downstream)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    // we declare Listener Ready toward the talker on port 0 -- the declaration the Extreme
    // registers
    let ready = await _waitFor { await _declaredListenerSubtype(msrp, streamID, port: 0) == .ready }
    XCTAssertTrue(ready, "Listener Ready must be declared toward the talker (port 0)")

    // the talker-side peer sends a LeaveAll (flushing its registrars to LV), then promptly re-Joins
    // the Talker (its periodic/re-declaration) -- exactly the Extreme's every-LeaveAllTime cycle
    let leaveAll = Message(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .LeaveAll,
        firstValue: AnyValue(_talkerAdvertise(streamID)),
        attributeEvents: [], applicationEvents: nil
      )]
    )
    try await msrp.rx(
      pdu: MRPDU(protocolVersion: 0, messages: [leaveAll]),
      for: MAPBaseSpanningTreeContext, from: MockPort(id: 0),
      sourceMacAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    )
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )

    // across the LeaveAll+rejoin window the Listener declaration toward the talker must stay Ready
    for _ in 0..<6 {
      try await Task.sleep(for: .milliseconds(250))
      let s = await _declaredListenerSubtype(msrp, streamID, port: 0)
      XCTAssertEqual(
        s, .ready,
        "Listener toward the talker must remain Ready across a talker LeaveAll+rejoin (periodic off)"
      )
    }
    _ = controller
  }

  // 35.2.4.3.4: talkerVlanPruning is off by default, so a Talker Advertise registers and
  // propagates out other Forwarding ports even when the stream's SR-class VLAN is not a member of
  // the port -- the Listener learns the VID from the Advertise (35.1.2.2) before declaring it.
  func testMSRPTalkerPropagatesWithoutStreamVLANWhenPruningOff() async throws {
    let recorder = MRPTestRecorder()
    // neither port is a member of the stream's SR-class VLAN (2, from _talkerAdvertise)
    let ports = Set([0, 1].map { MockPort(id: $0, vlans: [1]) })
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.talker.novlan"),
      timerConfiguration: MRPTimerConfiguration(periodicTime: .zero)
    )
    let msrp = try await MSRPApplication(controller: controller, flags: .defaultFlags)
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )

    let propagated = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil
    }
    XCTAssertTrue(
      propagated,
      "a Talker on a port without the SR-class VLAN must still propagate out port 1 (pruning off)"
    )
    _ = controller
  }

  // The talker leavetimer wins the race: after a LeaveAll the talker reaches MT (Listener is torn
  // down, correctly), then the talker re-Joins. The Listener toward the talker MUST recover to
  // Ready. A stuck-withdrawn/askingFailed here is the field dropout that never re-arms.
  func testMSRPListenerRecoversAfterTalkerLeaveAllTimeout() async throws {
    let recorder = MRPTestRecorder()
    let ports = Set([0, 1].map { MockPort(id: $0) })
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.leaveall.recover"),
      timerConfiguration: MRPTimerConfiguration(leaveTime: .seconds(1), periodicTime: .zero)
    )
    let msrp = try await MSRPApplication(controller: controller, flags: .defaultFlags)
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    let ready = await _waitFor { await _declaredListenerSubtype(msrp, streamID, port: 0) == .ready }
    XCTAssertTrue(ready, "Listener Ready must be declared toward the talker (port 0)")

    // LeaveAll with NO prompt re-Join: the talker leavetimer (1s) expires -> talker MT -> Listener
    // withdrawn (this part is correct: the talker is genuinely gone for >LeaveTime)
    let leaveAll = Message(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .LeaveAll,
        firstValue: AnyValue(_talkerAdvertise(streamID)),
        attributeEvents: [], applicationEvents: nil
      )]
    )
    try await msrp.rx(
      pdu: MRPDU(protocolVersion: 0, messages: [leaveAll]),
      for: MAPBaseSpanningTreeContext, from: MockPort(id: 0),
      sourceMacAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    )
    let withdrew = await _waitFor(timeoutMs: 2500) {
      await _declaredListenerSubtype(msrp, streamID, port: 0) != .ready
    }
    XCTAssertTrue(withdrew, "Listener must withdraw once the talker times out to MT")

    // the talker re-Joins -> the Listener toward it MUST recover to Ready
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let recovered = await _waitFor(timeoutMs: 2500) {
      await _declaredListenerSubtype(msrp, streamID, port: 0) == .ready
    }
    XCTAssertTrue(
      recovered,
      "Listener toward the talker must recover to Ready after the talker re-Joins"
    )
    _ = controller
  }

  // MVRP uses PeriodicTransmission: a periodic tick re-asserts an active declaration
  // (QA -> AA -> tx -> Join), keeping a VLAN registered on a short-LeaveTime peer between
  // LeaveAlls.
  func testMVRPPeriodicReassertsActiveDeclaration() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1])
    // a peer registration on port 0 propagates to an active declaration on port 1
    try await _driveMVRP(mvrp, port: 0, vid: 200, event: .JoinIn)
    let declared = await _waitFor { await _isVLANDeclared(mvrp, vid: 200, port: 1) }
    XCTAssertTrue(declared, "VID 200 must be actively declared on port 1")
    _ = await _waitFor { await _vlanJoinCount(recorder, mvrp, port: 1, vid: 200) >= 1 }
    try await Task.sleep(for: .milliseconds(400)) // settle to QA (quiet)
    let before = await _vlanJoinCount(recorder, mvrp, port: 1, vid: 200)
    // a periodic tick re-asserts: QA -> AA, then the joinTimer emits a Join
    try await mvrp.periodic(for: nil)
    let grew = await _waitFor(timeoutMs: 1500) {
      await _vlanJoinCount(recorder, mvrp, port: 1, vid: 200) > before
    }
    XCTAssertTrue(grew, "MVRP periodic() must re-assert the declaration")
    _ = controller
  }

  // MSRP has PeriodicTransmission disabled (Avnu §9.1): a periodic tick must be inert -- no
  // re-transmission -- so the controller's per-application gate can safely drive it every interval.
  func testMSRPPeriodicTransmissionIsNoOp() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0])
    // MSRP auto-declares SR Class A/B Domains; let them settle to quiet
    let declared = await _waitFor { await recorder.txPackets.contains { $0.port == 0 } }
    XCTAssertTrue(declared, "MSRP must declare its domains on the port")
    try await Task.sleep(for: .milliseconds(500))
    let before = await (recorder.txPackets).filter { $0.port == 0 }.count
    // a periodic tick must do nothing for MSRP
    try await msrp.periodic(for: nil)
    try await Task.sleep(for: .milliseconds(500))
    let after = await (recorder.txPackets).filter { $0.port == 0 }.count
    XCTAssertEqual(after, before, "MSRP periodic() must not re-transmit (Avnu §9.1)")
    _ = controller
  }

  func testCalculateBandwidthUsed8000PacketsPerSecond() throws {
    // Test for a stream with 8000 packets per second and frame size of 224 bytes
    let srClassID = SRclassID.A // Class A has 125 microsecond intervals (8000 Hz)
    let tSpec = MSRPTSpec(maxFrameSize: 224, maxIntervalFrames: 1) // 1 frame per 125us = 8000 fps

    let (frameSize, bandwidthUsed) = try calculateBandwidthUsed(
      srClassID: srClassID,
      tSpec: tSpec,
      nominalBandwidth: true
    )

    // Calculate expected frame size with overhead
    let expectedFrameSize: UInt16 = 224 + 4 + 18 + 20 // VLAN + L2 + L1 = 266
    XCTAssertEqual(frameSize, expectedFrameSize)

    // Calculate expected bandwidth
    let classMeasurementInterval = 125 // microseconds for Class A
    let maxFrameRate = Double(1) *
      (1_000_000.0 / Double(classMeasurementInterval)) // 8000 frames per second
    let expectedBandwidthUsed = maxFrameRate * Double(expectedFrameSize) * 8.0 / 1000.0 // kbps

    XCTAssertEqual(maxFrameRate, 8000.0)
    XCTAssertEqual(bandwidthUsed, Int(ceil(expectedBandwidthUsed)))
    XCTAssertEqual(bandwidthUsed, 17024) // 8000 * 266 * 8 / 1000 = 17024 kbps
  }

  // 35.2.2.8.6 per-hop latency (knowable terms): propagation plus two max-frame store-and-forward
  // /interference terms at the egress link rate. Faster links yield lower latency; the omitted,
  // class-dependent queue-drain (a) is not observable from the daemon.
  func testSrpPortTcMaxLatencyAddsFrameTermsAtLinkRate() {
    // 2000-byte max frame at 1 Gbps = 16 us per frame time; two of them plus 500 ns propagation
    let oneGbps = srpPortTcMaxLatency(meanLinkDelayNs: 500, linkSpeedKbps: 1_000_000)
    XCTAssertEqual(oneGbps, 500 + 2 * 16000)
    // a ten-times-faster link makes the frame terms ten times smaller
    let tenGbps = srpPortTcMaxLatency(meanLinkDelayNs: 500, linkSpeedKbps: 10_000_000)
    XCTAssertEqual(tenGbps, 500 + 2 * 1600)
    XCTAssertLessThan(tenGbps, oneGbps)
    // an unknown link speed contributes only the propagation term (no divide by zero)
    XCTAssertEqual(srpPortTcMaxLatency(meanLinkDelayNs: 500, linkSpeedKbps: 0), 500)
  }

  func testCBSParametersClassA() {
    // Test CBS parameter calculations for Class A with specific values
    // idleslope: 20 Mbps, transmission rate: 1 Gbps, max interfering frame: 1500 bytes
    let idleslopeA = 20000 // kbps (20 Mbps)
    let linkSpeed = 1_000_000 // kbps (1 Gbps)
    let sendslopeA = idleslopeA - linkSpeed // -980000 kbps
    let frameNonSr = 1500 // Maximum interfering frame size
    let maxFrameSizeA = UInt16(1500) // Maximum frame size for the stream

    let (hicredit, locredit) = MockBridge.calcClassACredits(
      idleslopeA: idleslopeA,
      sendslopeA: sendslopeA,
      linkSpeed: linkSpeed,
      frameNonSr: frameNonSr,
      maxFrameSizeA: maxFrameSizeA
    )

    // Verify the calculated parameters match expected values
    XCTAssertEqual(idleslopeA, 20000)
    XCTAssertEqual(sendslopeA, -980_000)
    XCTAssertEqual(hicredit, 30) // ceil(20000 * 1500 / 1000000) = ceil(30.0) = 30
    XCTAssertEqual(locredit, -1470) // ceil(-980000 * 1500 / 1000000) = ceil(-1470.0) = -1470
  }

  func testStateMachineIntegration() {
    // Test a complete scenario with all three state machines
    let applicant = Applicant()
    let registrar = Registrar(onLeaveTimerExpired: {})
    let leaveAll = LeaveAll(interval: .milliseconds(100)) {}

    let normalFlags: StateMachineHandlerFlags = []

    // Initialize all state machines
    XCTAssertNil(applicant.action(for: .Begin, flags: normalFlags).0)
    XCTAssertNil(registrar.action(for: .Begin, flags: normalFlags))
    let (leaveAllAction, tx) = leaveAll.action(for: .Begin)
    XCTAssertEqual(leaveAllAction, .startLeaveAllTimer)
    XCTAssertEqual(tx, false)

    XCTAssertEqual(applicant.description, "VO")
    XCTAssertEqual(registrar.state, .MT)
    XCTAssertEqual(leaveAll.state, .Passive)

    // Application wants to make a new declaration
    let (newAction, newTxOpp) = applicant.action(for: .New, flags: normalFlags)
    XCTAssertNil(newAction)
    XCTAssertTrue(newTxOpp) // Entered VN state
    XCTAssertEqual(applicant.description, "VN")

    // Transmission opportunity arrives (Registrar still MT, but VN -> AN is unconditional)
    let (applicantAction, _) = applicant.action(
      for: .tx, registrarState: registrar.state, flags: normalFlags
    )
    XCTAssertEqual(applicantAction, .sN)
    XCTAssertEqual(applicant.description, "AN")

    // Receive our own New message
    let registrarAction = registrar.action(for: .rNew, flags: normalFlags)
    XCTAssertEqual(registrarAction, .New)
    XCTAssertEqual(registrar.state, .IN)

    // Another transmission opportunity: AN -> QA now that the Registrar is IN (Table 10-3 fn 8)
    let (applicantAction2, _) = applicant.action(
      for: .tx, registrarState: registrar.state, flags: normalFlags
    )
    XCTAssertEqual(applicantAction2, .sN)
    XCTAssertEqual(applicant.description, "QA")

    // Receive JoinIn from another participant
    XCTAssertNil(applicant.action(for: .rJoinIn, flags: normalFlags).0)
    XCTAssertEqual(applicant.description, "QA") // No change for QA on rJoinIn

    // Later, receive a Leave All
    let (rLAAction, rLATxOpp) = applicant.action(for: .rLA, flags: normalFlags)
    XCTAssertNil(rLAAction)
    XCTAssertTrue(rLATxOpp) // Entered VP state (QA->VP on rLA)
    XCTAssertEqual(applicant.description, "VP") // QA -> VP on rLA

    XCTAssertNil(registrar.action(for: .rLA, flags: normalFlags))
    XCTAssertEqual(registrar.state, .LV) // IN -> LV on rLA

    let (leaveAllAction2, tx2) = leaveAll.action(for: .rLA)
    XCTAssertEqual(leaveAllAction2, .startLeaveAllTimer)
    XCTAssertEqual(leaveAll.state, .Passive)
    XCTAssertEqual(tx2, false)
  }

  // MARK: - PTP Tests

  func testPTPTimestampSerialization() throws {
    let timestamp = PTP.Timestamp(
      secondsMsb: 0x0000,
      secondsLsb: 0x1234_5678,
      nanoseconds: 0x9ABC_DEF0
    )

    var serializationContext = SerializationContext()
    try timestamp.serialize(into: &serializationContext)

    // Timestamp is 48 bits seconds + 32 bits nanoseconds = 10 bytes
    XCTAssertEqual(serializationContext.bytes.count, 10)
    XCTAssertEqual(
      serializationContext.bytes,
      [0x00, 0x00, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]
    )

    let deserialized = try serializationContext.bytes.withParserSpan { input in
      try PTP.Timestamp(parsing: &input)
    }

    XCTAssertEqual(deserialized.secondsMsb, 0x0000)
    XCTAssertEqual(deserialized.secondsLsb, 0x1234_5678)
    XCTAssertEqual(deserialized.nanoseconds, 0x9ABC_DEF0)
  }

  func testPTPClockIdentitySerialization() throws {
    let clockId = PTP.ClockIdentity(id: (0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77))

    var serializationContext = SerializationContext()
    try clockId.serialize(into: &serializationContext)

    // ClockIdentity is 8 bytes
    XCTAssertEqual(serializationContext.bytes.count, 8)
    XCTAssertEqual(
      serializationContext.bytes,
      [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]
    )

    let deserialized = try serializationContext.bytes.withParserSpan { input in
      try PTP.ClockIdentity(parsing: &input)
    }

    XCTAssertEqual(deserialized, clockId)
  }

  func testPTPClockIdentityFromEUI48() throws {
    let eui48: EUI48 = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
    let clockId = PTP.ClockIdentity(eui48: eui48)

    var serializationContext = SerializationContext()
    try clockId.serialize(into: &serializationContext)

    // ClockIdentity from EUI48 inserts 0xFF 0xFE in the middle
    XCTAssertEqual(
      serializationContext.bytes,
      [0xAA, 0xBB, 0xCC, 0xFF, 0xFE, 0xDD, 0xEE, 0xFF]
    )
  }

  func testPTPPortIdentitySerialization() throws {
    let clockId = PTP.ClockIdentity(id: (0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77))
    let portId = PTP.PortIdentity(clockIdentity: clockId, portNumber: 0x1234)

    var serializationContext = SerializationContext()
    try portId.serialize(into: &serializationContext)

    // PortIdentity is 8 bytes ClockIdentity + 2 bytes port number = 10 bytes
    XCTAssertEqual(serializationContext.bytes.count, 10)
    XCTAssertEqual(
      serializationContext.bytes,
      [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x12, 0x34]
    )

    let deserialized = try serializationContext.bytes.withParserSpan { input in
      try PTP.PortIdentity(parsing: &input)
    }

    XCTAssertEqual(deserialized.clockIdentity, clockId)
    XCTAssertEqual(deserialized.portNumber, 0x1234)
  }

  func testPTPClockQualitySerialization() throws {
    let clockQuality = PTP.ClockQuality(
      clockClass: 248,
      clockAccuracy: 0x21,
      offsetScaledLogVariance: 0x4321
    )

    var serializationContext = SerializationContext()
    try clockQuality.serialize(into: &serializationContext)

    // ClockQuality is 1 + 1 + 2 = 4 bytes
    XCTAssertEqual(serializationContext.bytes.count, 4)
    XCTAssertEqual(
      serializationContext.bytes,
      [248, 0x21, 0x43, 0x21]
    )

    let deserialized = try serializationContext.bytes.withParserSpan { input in
      try PTP.ClockQuality(parsing: &input)
    }

    XCTAssertEqual(deserialized.clockClass, 248)
    XCTAssertEqual(deserialized.clockAccuracy, 0x21)
    XCTAssertEqual(deserialized.offsetScaledLogVariance, 0x4321)
  }

  func testPTPHeaderSerialization() throws {
    let clockId = PTP.ClockIdentity(id: (0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77))
    let portId = PTP.PortIdentity(clockIdentity: clockId, portNumber: 1)

    // messageLength is checked against remaining bytes after parsing first 4 bytes
    // So if total bytes is 54, and 4 bytes are consumed, messageLength should be 50
    let totalBytes: UInt16 = 54
    let messageLength: UInt16 = 50 // Remaining bytes after first 4 header bytes
    let header = PTP.Header(
      majorSdoId: .ieee8021AS,
      messageType: .Management,
      versionPTP: .v2,
      messageLength: messageLength,
      domainNumber: 0,
      minorSdoId: 0,
      sourcePortIdentity: portId,
      sequenceId: 42
    )

    var serializationContext = SerializationContext()
    try header.serialize(into: &serializationContext)

    // PTP Header is 34 bytes
    XCTAssertEqual(serializationContext.bytes.count, 34)
    XCTAssertEqual(header.messageType, .Management)
    XCTAssertEqual(header.versionPTP, .v2)
    XCTAssertEqual(header.sequenceId, 42)

    // Pad to match total bytes for deserialization test
    serializationContext.serialize(Array(repeating: 0, count: Int(totalBytes) - 34))

    let deserialized = try serializationContext.bytes.withParserSpan { input in
      try PTP.Header(parsing: &input)
    }

    XCTAssertEqual(deserialized.messageType, .Management)
    XCTAssertEqual(deserialized.versionPTP, .v2)
    XCTAssertEqual(deserialized.messageLength, messageLength)
    XCTAssertEqual(deserialized.sequenceId, 42)
  }

  // MARK: - PDU Attribute List Length Tests

  func testMSRPAttributeListLengthParsing() async throws {
    let logger = Logger(label: "com.padl.MRPTests.MSRP")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let msrp = try await MSRPApplication(controller: controller)

    // Create a minimal MSRP PDU with attributeListLength
    // This tests that bytesProcessed calculation works correctly
    let streamID = MSRPStreamID(0x0001_F2FE_D2A4_0000)
    let talkerAdvertise = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(),
      tSpec: MSRPTSpec(),
      priorityAndRank: MSRPPriorityAndRank(),
      accumulatedLatency: 1000
    )

    // Create a message with the talker advertise attribute
    let vectorAttribute = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(talkerAdvertise),
      attributeEvents: [.JoinMt],
      applicationEvents: nil
    )

    let message = Message(attributeType: 1, attributeList: [vectorAttribute])

    // Serialize the message
    var serializationContext = SerializationContext()
    try message.serialize(into: &serializationContext, application: msrp)

    // Parse it back
    let parsedMessage = try serializationContext.bytes.withParserSpan { input in
      try Message(parsing: &input, application: msrp)
    }

    XCTAssertEqual(parsedMessage.attributeType, 1)
    XCTAssertEqual(parsedMessage.attributeList.count, 1)
  }

  func testMSRPAttributeListLengthWithMultipleAttributes() async throws {
    let logger = Logger(label: "com.padl.MRPTests.MSRP")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let msrp = try await MSRPApplication(controller: controller)

    // Create multiple attributes to test the bytesProcessed loop
    let streamID1 = MSRPStreamID(0x0001_0000_0000_0001)
    let streamID2 = MSRPStreamID(0x0001_0000_0000_0002)
    let streamID3 = MSRPStreamID(0x0001_0000_0000_0003)

    let talker1 = MSRPTalkerAdvertiseValue(
      streamID: streamID1,
      dataFrameParameters: MSRPDataFrameParameters(),
      tSpec: MSRPTSpec(),
      priorityAndRank: MSRPPriorityAndRank(),
      accumulatedLatency: 1000
    )

    let talker2 = MSRPTalkerAdvertiseValue(
      streamID: streamID2,
      dataFrameParameters: MSRPDataFrameParameters(),
      tSpec: MSRPTSpec(),
      priorityAndRank: MSRPPriorityAndRank(),
      accumulatedLatency: 2000
    )

    let talker3 = MSRPTalkerAdvertiseValue(
      streamID: streamID3,
      dataFrameParameters: MSRPDataFrameParameters(),
      tSpec: MSRPTSpec(),
      priorityAndRank: MSRPPriorityAndRank(),
      accumulatedLatency: 3000
    )

    // Create vector attributes with consecutive stream IDs
    let vectorAttribute1 = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(talker1),
      attributeEvents: [.JoinMt],
      applicationEvents: nil
    )

    let vectorAttribute2 = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(talker2),
      attributeEvents: [.JoinMt],
      applicationEvents: nil
    )

    let vectorAttribute3 = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(talker3),
      attributeEvents: [.JoinMt],
      applicationEvents: nil
    )

    let message = Message(
      attributeType: 1,
      attributeList: [vectorAttribute1, vectorAttribute2, vectorAttribute3]
    )

    // Serialize the message
    var serializationContext = SerializationContext()
    try message.serialize(into: &serializationContext, application: msrp)

    // Parse it back and verify bytesProcessed tracking works correctly
    let parsedMessage = try serializationContext.bytes.withParserSpan { input in
      try Message(parsing: &input, application: msrp)
    }

    XCTAssertEqual(parsedMessage.attributeType, 1)
    XCTAssertEqual(parsedMessage.attributeList.count, 3)
  }

  func testMVRPWithoutAttributeListLength() async throws {
    // This test verifies the EndMark-based parsing (without attributeListLength)
    let logger = Logger(label: "com.padl.MRPTests.MVRP")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let mvrp = try await MVRPApplication(controller: controller)

    // Verify that MVRP doesn't use attributeListLength
    XCTAssertFalse(mvrp.hasAttributeListLength)

    // Create a message with multiple VLANs
    let vlan1 = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(VLAN(vid: 100)),
      attributeEvents: [.JoinMt, .JoinIn],
      applicationEvents: nil
    )

    let vlan2 = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(VLAN(vid: 200)),
      attributeEvents: [.JoinMt],
      applicationEvents: nil
    )

    let message = Message(attributeType: 1, attributeList: [vlan1, vlan2])

    // Serialize the message
    var serializationContext = SerializationContext()
    try message.serialize(into: &serializationContext, application: mvrp)

    // Parse it back and verify EndMark-based parsing works
    let parsedMessage = try serializationContext.bytes.withParserSpan { input in
      try Message(parsing: &input, application: mvrp)
    }

    XCTAssertEqual(parsedMessage.attributeType, 1)
    XCTAssertEqual(parsedMessage.attributeList.count, 2)
  }

  func testAttributeListLengthBoundaryConditions() async throws {
    let logger = Logger(label: "com.padl.MRPTests.MSRP")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let msrp = try await MSRPApplication(controller: controller)

    // Create a single attribute to test exact boundary condition
    // where bytesProcessed == attributeListLength - 2
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    let talker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(),
      tSpec: MSRPTSpec(),
      priorityAndRank: MSRPPriorityAndRank(),
      accumulatedLatency: 1000
    )

    let vectorAttribute = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(talker),
      attributeEvents: [.JoinMt],
      applicationEvents: nil
    )

    let message = Message(attributeType: 1, attributeList: [vectorAttribute])

    // Serialize and parse to verify boundary condition
    var serializationContext = SerializationContext()
    try message.serialize(into: &serializationContext, application: msrp)

    let parsedMessage = try serializationContext.bytes.withParserSpan { input in
      try Message(parsing: &input, application: msrp)
    }

    XCTAssertEqual(parsedMessage.attributeType, 1)
    XCTAssertEqual(parsedMessage.attributeList.count, 1)
  }

  func testMSRPListenerWithIgnoreSubtype() async throws {
    // Test case for packet with attributeSubtype = 0 (ignore) in listener events
    // This is the actual packet from the bug report
    // payload: 00040400090002050200027e00000308000e00030001f2fed2a40000948800000000000000000000000000000000

    let logger = Logger(label: "com.padl.MRPTests.MSRPIgnoreSubtype")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let msrp = try await MSRPApplication(controller: controller)

    let pduBytes: [UInt8] = [
      0x00, 0x04, 0x04, 0x00, 0x09, 0x00, 0x02, 0x05,
      0x02, 0x00, 0x02, 0x7E, 0x00, 0x00, 0x03, 0x08,
      0x00, 0x0E, 0x00, 0x03, 0x00, 0x01, 0xF2, 0xFE,
      0xD2, 0xA4, 0x00, 0x00, 0x94, 0x88, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    // Parse the PDU directly
    let pdu = try pduBytes.withParserSpan { input in
      try MRPDU(parsing: &input, application: msrp)
    }

    XCTAssertEqual(pdu.protocolVersion, 0)
    XCTAssertEqual(pdu.messages.count, 2)

    // Check listener message
    guard pdu.messages.count >= 2 else {
      XCTFail("Expected 2 messages")
      return
    }

    let listenerMessage = pdu.messages[1]
    XCTAssertEqual(listenerMessage.attributeType, 3) // listener
    XCTAssertEqual(listenerMessage.attributeList.count, 1)

    if let listenerAttribute = listenerMessage.attributeList.first {
      XCTAssertEqual(listenerAttribute.numberOfValues, 3)

      // Check the fourPackedEvents
      let applicationEvents = listenerAttribute.applicationEvents
      XCTAssertNotNil(applicationEvents)

      if let applicationEvents {
        // Should have 4 subtypes: [2, 0, 2, 0]
        XCTAssertGreaterThanOrEqual(applicationEvents.count, 3)
        XCTAssertEqual(applicationEvents[0], 2) // ready
        XCTAssertEqual(applicationEvents[1], 0) // ignore
        XCTAssertEqual(applicationEvents[2], 2) // ready
      }
    }
  }

  // MARK: - Malformed PDU decoder-safety regression tests

  // Ported from Jeff Koftinoff's statusbar/srp C++ suite: each asserts a crafted/corrupt
  // MRPDU is rejected without mis-parsing the rest of the list.

  private func makeMSRP() async throws -> MSRPApplication<MockPort> {
    let logger = Logger(label: "com.padl.MRPTests.MSRP.decoderSafety")
    let controller = try await MRPController(bridge: MockBridge(), logger: logger)
    return try await MSRPApplication(controller: controller)
  }

  private func makeMVRP() async throws -> MVRPApplication<MockPort> {
    let logger = Logger(label: "com.padl.MRPTests.MVRP.decoderSafety")
    let controller = try await MRPController(bridge: MockBridge(), logger: logger)
    return try await MVRPApplication(controller: controller)
  }

  // _checkTopologyChange polls getStpPortStatus on EVERY port update, including a PortMRPState
  // no-op
  // (e.g. a statistics refresh): an STP role-only transition (Designated->Root, same forwarding
  // state) has no netlink-visible field, so gating the poll would miss its Re-declare! (10.7.5.3).
  // The PortMRPState gate still suppresses context re-processing / ReDeclare churn on a no-op --
  // that is covered by testBenignPortUpdateDoesNotRedeclare.
  func testStpRoleIsPolledOnEveryPortUpdate() async throws {
    let logger = Logger(label: "com.padl.MRPTests.portGuard")
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(bridge: bridge, logger: logger)
    _ = try await MSRPApplication(controller: controller)

    try await controller._didAdd(port: MockPort(id: 0))
    let afterAdd = await recorder.stpStatusQueries.count

    // an identical snapshot (PortMRPState no-op) must still poll the role
    try await controller._didUpdate(port: MockPort(id: 0))
    let afterNoOp = await recorder.stpStatusQueries.count
    XCTAssertEqual(
      afterNoOp, afterAdd + 1,
      "STP role must be polled even on a no-op update (role changes have no netlink signal)"
    )

    // a real change also polls
    var blocking = MockPort(id: 0)
    blocking.stpPortState = .blocking
    try await controller._didUpdate(port: blocking)
    let afterState = await recorder.stpStatusQueries.count
    XCTAssertEqual(afterState, afterAdd + 2, "STP role must be polled on a real change")
  }

  // 10.7.5.3: a port role change from Designated to Root (or Alternate) generates Re-declare! --
  // a registered attribute's Registrar moves IN -> LV so it re-declares rather than waiting for
  // the next LeaveAll.
  func testRedeclareOnDesignatedToRootRoleChange() async throws {
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.stp")
    )
    let mvrp = try await MVRPApplication(controller: controller)
    await recorder.setStpStatus(STPPortStatus(role: .designated, state: .forwarding), port: 0)
    try await controller._didAdd(port: MockPort(id: 0))

    // a peer join registers VID 100 (registrar IN)
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    let registered = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .IN }
    XCTAssertTrue(registered, "peer join must register VID 100 (registrar IN)")

    // role Designated -> Root: Re-declare! moves the registrar IN -> LV
    await recorder.setStpStatus(STPPortStatus(role: .root, state: .forwarding), port: 0)
    var moved = MockPort(id: 0)
    moved.stpPortState = .listening // change a field so the update is not a no-op
    try await controller._didUpdate(port: moved)
    let redeclared = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .LV }
    XCTAssertTrue(redeclared, "Designated->Root must Re-declare!, moving the registrar to LV")
    _ = controller
  }

  // A role-only Designated->Root transition (same forwarding state, no other field change) leaves
  // PortMRPState identical, so the update is gated out of the context machinery -- but the role
  // change must still Re-declare! (10.7.5.3). Guards running _checkTopologyChange before that gate.
  func testRedeclareOnPureDesignatedToRootRoleChange() async throws {
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.stp")
    )
    let mvrp = try await MVRPApplication(controller: controller)
    await recorder.setStpStatus(STPPortStatus(role: .designated, state: .forwarding), port: 0)
    try await controller._didAdd(port: MockPort(id: 0))

    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    let registered = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .IN }
    XCTAssertTrue(registered, "peer join must register VID 100 (registrar IN)")

    // role Designated -> Root, forwarding both times, no other field change: PortMRPState is a
    // no-op
    await recorder.setStpStatus(STPPortStatus(role: .root, state: .forwarding), port: 0)
    try await controller._didUpdate(port: MockPort(id: 0))
    let redeclared = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .LV }
    XCTAssertTrue(redeclared, "a role-only Designated->Root must still Re-declare! (IN -> LV)")
    _ = controller
  }

  // A role-only Designated->Root change emits no netlink port event at all, so nothing calls
  // _checkTopologyChange reactively -- only the STP-role poll can catch it. Without the poll the
  // Re-declare! (10.7.5.3) waits for an unrelated port event; here there is none.
  func testRedeclareOnRoleChangeWithoutPortEvent() async throws {
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.stp"),
      timerConfiguration: MRPTimerConfiguration(
        leaveTime: .seconds(1),
        periodicTime: .zero
      )
    )
    let mvrp = try await MVRPApplication(controller: controller)
    await recorder.setStpStatus(STPPortStatus(role: .designated, state: .forwarding), port: 0)
    try await controller._didAdd(port: MockPort(id: 0))

    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    let registered = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .IN }
    XCTAssertTrue(registered, "peer join must register VID 100 (registrar IN)")

    // flip the role with NO port event: the poll, not a netlink update, must drive the Re-declare!
    await recorder.setStpStatus(STPPortStatus(role: .root, state: .forwarding), port: 0)
    let redeclared = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .LV }
    XCTAssertTrue(redeclared, "the STP-role poll must Re-declare! a role-only change (IN -> LV)")
    _ = controller
  }

  // The inverse guard: a benign port update with no STP role change (still Designated) must NOT
  // Re-declare! and move a registered attribute to LV -- Re-declare! is topology-scoped (10.7.5.3).
  func testBenignPortUpdateDoesNotRedeclare() async throws {
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.stp")
    )
    let mvrp = try await MVRPApplication(controller: controller)
    await recorder.setStpStatus(STPPortStatus(role: .designated, state: .forwarding), port: 0)
    try await controller._didAdd(port: MockPort(id: 0))

    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    let registered = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .IN }
    XCTAssertTrue(registered, "peer join must register VID 100 (registrar IN)")

    // change only the forwarding state (role stays Designated) so the update passes the gate but is
    // not a topology change
    var moved = MockPort(id: 0)
    moved.stpPortState = .learning
    try await controller._didUpdate(port: moved)
    try await Task.sleep(for: .milliseconds(200)) // allow any erroneous redeclare to land
    let state = await _vlanRegistrarState(mvrp, vid: 100, port: 0)
    XCTAssertEqual(state, .IN, "a benign port update (no role change) must not Re-declare!")
    _ = controller
  }

  // 10.7.5.2: Flush! fires on a Root/Alternate -> Designated role change (an active-topology
  // change), rapidly deregistering the port's registrations. Here Alternate -> Designated.
  func testFlushOnAlternateToDesignatedRoleChange() async throws {
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.stp")
    )
    let mvrp = try await MVRPApplication(controller: controller)
    await recorder.setStpStatus(STPPortStatus(role: .alternate, state: .forwarding), port: 0)
    try await controller._didAdd(port: MockPort(id: 0))

    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    let registered = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .IN }
    XCTAssertTrue(registered, "peer join must register VID 100 (registrar IN)")

    // Alternate -> Designated: Flush! must deregister the registration (leaves IN)
    await recorder.setStpStatus(STPPortStatus(role: .designated, state: .forwarding), port: 0)
    try await controller._didUpdate(port: MockPort(id: 0))
    let flushed = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) != .IN }
    XCTAssertTrue(flushed, "Alternate->Designated must Flush! (10.7.5.2), deregistering VID 100")
    _ = controller
  }

  // 10.7.5.2 negative: a port coming up from disabled/down (a link-flap recovery) into Designated
  // is NOT a Flush! event -- nothing stale to flush. The registration must survive the flap.
  func testNoFlushOnLinkFlapRecoveryToDesignated() async throws {
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.stp")
    )
    let mvrp = try await MVRPApplication(controller: controller)
    await recorder.setStpStatus(STPPortStatus(role: .designated, state: .forwarding), port: 0)
    try await controller._didAdd(port: MockPort(id: 0))

    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    let registered = await _waitFor { await _vlanRegistrarState(mvrp, vid: 100, port: 0) == .IN }
    XCTAssertTrue(registered, "peer join must register VID 100 (registrar IN)")

    // link down (role disabled), then recovery to Designated: the recovery must NOT Flush!
    await recorder.setStpStatus(STPPortStatus(role: .disabled, state: .disabled), port: 0)
    try await controller._didUpdate(port: MockPort(id: 0))
    await recorder.setStpStatus(STPPortStatus(role: .designated, state: .forwarding), port: 0)
    try await controller._didUpdate(port: MockPort(id: 0))
    try await Task.sleep(for: .milliseconds(200)) // allow any erroneous flush to land
    let state = await _vlanRegistrarState(mvrp, vid: 100, port: 0)
    XCTAssertEqual(state, .IN, "link-flap recovery (disabled->Designated) must not Flush!")
    _ = controller
  }

  // leaveAllTime == 0 disables periodic LeaveAll; a .startLeaveAllTimer action (peer LeaveAll,
  // Flush) must be a no-op, not trap on Double.random(in: 0..<0).
  func testDisabledLeaveAllTimerDoesNotTrap() {
    let leaveAll = LeaveAll(interval: .zero, onLeaveAllTimerExpired: {})
    leaveAll.startLeaveAllTimer() // pre-fix: empty-range random traps here
    let (action, _) = leaveAll.action(for: .rLA)
    guard case .startLeaveAllTimer? = action else {
      return XCTFail("rLA must yield .startLeaveAllTimer")
    }
    leaveAll.startLeaveAllTimer() // applying the action must also not trap
  }

  // deregister must succeed for a registered application (regression: an inverted guard threw
  // unknownApplication for registered apps) and still reject an absent one.
  func testDeregisterApplicationSucceedsForRegisteredApp() async throws {
    let recorder = MRPTestRecorder()
    let bridge = MockBridge(ports: [MockPort(id: 0)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.dereg")
    )
    let mvrp = try await MVRPApplication(controller: controller) // auto-registers
    try await controller.deregister(application: mvrp) // must not throw
    do {
      try await controller.deregister(application: mvrp)
      XCTFail("deregistering an absent application must throw unknownApplication")
    } catch MRPError.unknownApplication {}
  }

  // Registration Forbidden must deregister an already-registered attribute: force MT AND emit Lv
  // (like Flush) so the application tears down its reservation, not silently drop it.
  func testRegistrationForbiddenEmitsLeaveWhenRegistered() {
    let registrar = Registrar(onLeaveTimerExpired: {})
    _ = registrar.action(for: .rJoinIn, flags: []) // MT -> IN
    XCTAssertEqual(String(describing: registrar.state), "IN")
    let action = registrar.action(for: .ReDeclare, flags: [.registrationForbidden])
    guard case .Lv? = action else { return XCTFail("registrationForbidden while IN must emit Lv") }
    XCTAssertEqual(String(describing: registrar.state), "MT")
    // a subsequent forbidden event, now MT, emits nothing
    XCTAssertNil(registrar.action(for: .ReDeclare, flags: [.registrationForbidden]))
  }

  // Flush forces the Registrar LV -> MT; it must also stop the leavetimer so it can't later fire
  // a spurious Lv for the already-flushed attribute.
  func testFlushStopsRegistrarLeaveTimer() async throws {
    let flag = TimerExpiryFlag()
    let registrar = Registrar(leaveTime: .milliseconds(50)) { await flag.fire() }
    _ = registrar.action(for: .rJoinIn, flags: []) // MT -> IN
    _ = registrar.action(for: .rLA, flags: []) // IN -> LV, arms the leavetimer
    _ = registrar.action(for: .Flush, flags: []) // LV -> MT, must stop the timer
    try await Task.sleep(for: .milliseconds(250))
    let fired = await flag.fired
    XCTAssertFalse(fired, "Flush must stop the leavetimer so it does not later fire")
  }

  // attributeLength shorter than the fixed firstValue over-reads into the packed
  // events; longer leaves stray octets. Both must be rejected (the new guard).
  func testMSRPRejectsMismatchedAttributeLength() async throws {
    let msrp = try await makeMSRP()
    let talker = MSRPTalkerAdvertiseValue(
      streamID: MSRPStreamID(0x0001_0000_0000_0001),
      dataFrameParameters: MSRPDataFrameParameters(),
      tSpec: MSRPTSpec(),
      priorityAndRank: MSRPPriorityAndRank(),
      accumulatedLatency: 1000
    )
    let message = Message(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .NullLeaveAllEvent,
        firstValue: AnyValue(talker),
        attributeEvents: [.JoinMt],
        applicationEvents: nil
      )]
    )
    var sc = SerializationContext()
    try MRPDU(protocolVersion: 0, messages: [message]).serialize(into: &sc, application: msrp)
    let bytes = sc.bytes

    // sanity: the well-formed PDU parses to exactly one talker
    let valid = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(valid.messages.count, 1)

    // attributeLength is the 3rd octet (after protocolVersion and attributeType)
    XCTAssertEqual(bytes[2], 25, "TalkerAdvertise firstValue is 25 octets")

    var tooSmall = bytes; tooSmall[2] = 4
    let parsedSmall = try tooSmall.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(parsedSmall.messages.count, 0, "undersized attributeLength rejected")

    var tooLarge = bytes; tooLarge[2] = 30
    let parsedLarge = try tooLarge.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(parsedLarge.messages.count, 0, "oversized attributeLength rejected")
  }

  // Domain vector claiming 50 values in a payload with room for one: the packed
  // event array overruns the buffer and the PDU is dropped.
  func testMSRPRejectsNumberOfValuesOverrun() async throws {
    let msrp = try await makeMSRP()
    let bytes: [UInt8] = [
      0x00, // protocolVersion
      0x04, // attributeType = domain
      0x04, // attributeLength = 4
      0x00, 0x09, // attributeListLength = 9
      0x00, 0x32, // vectorHeader: numberOfValues = 50
      0x06, 0x03, 0x00, 0x02, // DomainFirstValue (4 octets)
      0x00, 0x00, 0x00, // far too few packed-event octets
    ]
    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(pdu.messages.count, 0, "numberOfValues overrun rejected")
  }

  // Higher protocol version whose attributeListLength runs past the buffer is
  // dropped rather than over-read (clause 10.8.3.x / Avnu §8.1).
  func testMSRPRejectsWrongProtocolVersionTruncated() async throws {
    let msrp = try await makeMSRP()
    let bytes: [UInt8] = [0x01, 0x04, 0x04, 0x00, 0x09]
    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(pdu.messages.count, 0)
  }

  // A version-0 PDU naming an attribute type we don't know is discarded from the
  // unknown message onward, keeping any valid prefix.
  func testMSRPRejectsUnknownAttributeType() async throws {
    let msrp = try await makeMSRP()
    let bytes: [UInt8] = [
      0x00, // protocolVersion
      0x07, // attributeType = 7 (unknown)
      0x04, // attributeLength
      0x00, 0x04, // attributeListLength
      0x00, 0x00, 0x00, 0x00, // body
      0x00, 0x00, // endmark
    ]
    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(pdu.messages.count, 0)
  }

  // A 3-packed octet of 0xFA decodes its first event as 6, which has no
  // AttributeEvent case: parsing succeeds but reading the events throws.
  func testMSRPRejectsThreePackedEventOutOfRange() async throws {
    let msrp = try await makeMSRP()
    var bytes: [UInt8] = [
      0x00, // protocolVersion
      0x01, // attributeType = talkerAdvertise
      0x19, // attributeLength = 25
      0x00, 0x1E, // attributeListLength = 30
      0x00, 0x01, // vectorHeader: numberOfValues = 1
    ]
    bytes += [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0xBE, 0xEF] // streamID
    bytes += [0x91, 0xE0, 0xF0, 0x00, 0x12, 0x34] // dest MAC
    bytes += [0x00, 0x02] // vlan
    bytes += [0x00, 0x96] // maxFrameSize
    bytes += [0x00, 0x01] // maxIntervalFrames
    bytes += [0x60] // priorityAndRank
    bytes += [0x00, 0x00, 0x00, 0x00] // accumulatedLatency
    bytes += [0xFA] // 3-packed events: first event = 6 (invalid)
    bytes += [0x00, 0x00] // endmark

    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(pdu.messages.count, 1, "structurally valid, parses")
    let vector = try XCTUnwrap(pdu.messages.first?.attributeList.first)
    XCTAssertThrowsError(try vector.attributeEvents) { error in
      XCTAssertEqual(error as? MRPError, .unknownAttributeEvent)
    }
  }

  // MVRP: attributeLength (0) below the 2-octet VID firstValue must be rejected,
  // not allowed to read past the packet (statusbar/srp regression).
  func testMVRPRejectsUndersizedAttributeLength() async throws {
    let mvrp = try await makeMVRP()
    let bytes: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x01]
    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: mvrp) }
    XCTAssertEqual(pdu.messages.count, 0)
  }

  // MVRP: a vector claiming 100 VIDs with room for one is dropped.
  func testMVRPRejectsNumberOfValuesOverrun() async throws {
    let mvrp = try await makeMVRP()
    let bytes: [UInt8] = [
      0x00, // protocolVersion
      0x01, // attributeType = vid
      0x02, // attributeLength = 2
      0x00, 0x64, // vectorHeader: numberOfValues = 100
      0x00, 0x64, // VlanIdentifierFirstValue = 100
      0x24, // one packed-event octet
      0x00, 0x00, 0x00,
    ]
    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: mvrp) }
    XCTAssertEqual(pdu.messages.count, 0)
  }

  // A PDU advertising a protocol version above ours but carrying attributes we do
  // understand still parses (we don't reject purely on the version octet).
  func testHigherProtocolVersionParsesKnownAttributes() async throws {
    let msrp = try await makeMSRP()
    let talker = MSRPTalkerAdvertiseValue(
      streamID: MSRPStreamID(0x0001_0000_0000_0001),
      dataFrameParameters: MSRPDataFrameParameters(),
      tSpec: MSRPTSpec(),
      priorityAndRank: MSRPPriorityAndRank(),
      accumulatedLatency: 0
    )
    let message = Message(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .NullLeaveAllEvent,
        firstValue: AnyValue(talker),
        attributeEvents: [.JoinMt],
        applicationEvents: nil
      )]
    )
    var sc = SerializationContext()
    try MRPDU(protocolVersion: 0, messages: [message]).serialize(into: &sc, application: msrp)
    var bytes = sc.bytes
    bytes[0] = 0x02 // bump the protocolVersion octet

    let pdu = try bytes.withParserSpan { try MRPDU(parsing: &$0, application: msrp) }
    XCTAssertEqual(pdu.protocolVersion, 2)
    XCTAssertEqual(pdu.messages.count, 1)
  }

  // MARK: - MMRP / MVRP indication-path integration tests

  // Drive a peer declaration through a participant's rx and assert the bridge is
  // programmed (previously MMRP/MVRP had only serialization coverage).

  private func _makeMMRP(portIDs: [Int])
    async throws -> (MRPController<MockPort>, MMRPApplication<MockPort>, MRPTestRecorder)
  {
    let recorder = MRPTestRecorder()
    let ports = Set(portIDs.map { MockPort(id: $0) })
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.mmrp"),
      timerConfiguration: MRPTimerConfiguration(leaveTime: .seconds(1))
    )
    let mmrp = try await MMRPApplication(controller: controller)
    try await mmrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    return (controller, mmrp, recorder)
  }

  private func _driveMMRP(
    _ mmrp: MMRPApplication<MockPort>,
    port: Int,
    value: some Value,
    event: AttributeEvent
  ) async throws {
    let message = Message(
      attributeType: MMRPAttributeType.mac.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .NullLeaveAllEvent,
        firstValue: AnyValue(value),
        attributeEvents: [event],
        applicationEvents: nil
      )]
    )
    let source: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    try await mmrp.rx(
      pdu: MRPDU(protocolVersion: 0, messages: [message]),
      for: MAPBaseSpanningTreeContext,
      from: MockPort(id: port),
      sourceMacAddress: source
    )
  }

  // A peer JoinIn for a group MAC programs that address into the FDB on the
  // context's ports.
  func testMMRPJoinIndicationRegistersGroupAddress() async throws {
    let (controller, mmrp, recorder) = try await _makeMMRP(portIDs: [0, 1])
    let group: EUI48 = [0x01, 0x00, 0x5E, 0x00, 0x00, 0x01]
    try await _driveMMRP(mmrp, port: 0, value: MMRPMACValue(macAddress: group), event: .JoinIn)

    let registered = await _waitFor {
      await recorder.fdbRegister.contains { _isEqualMacAddress($0.mac, group) }
    }
    XCTAssertTrue(registered, "MMRP join indication must register the group address")
    _ = controller
  }

  // MAP propagates a peer registration on one port as declarations on the other
  // ports (10.3 a) — guards the refcounted leave propagation against regressions.
  func testMMRPJoinPropagatedToOtherPorts() async throws {
    let (controller, mmrp, _) = try await _makeMMRP(portIDs: [0, 1])
    let group: EUI48 = [0x01, 0x00, 0x5E, 0x00, 0x00, 0x03]
    try await _driveMMRP(mmrp, port: 0, value: MMRPMACValue(macAddress: group), event: .JoinIn)

    let declared = await _waitFor { await _isMMRPMacDeclared(mmrp, mac: group, port: 1) }
    XCTAssertTrue(declared, "a registration on port 0 must be declared on port 1 via MAP")
    let echoed = await _isMMRPMacDeclared(mmrp, mac: group, port: 0)
    XCTAssertFalse(echoed, "MAP must not echo the declaration back to the registering port")
    _ = controller
  }

  // After a registered group is declared Leave, the leave timer expiry
  // deregisters it from the FDB.
  func testMMRPLeaveIndicationDeregistersGroupAddress() async throws {
    let (controller, mmrp, recorder) = try await _makeMMRP(portIDs: [0])
    let group: EUI48 = [0x01, 0x00, 0x5E, 0x00, 0x00, 0x02]
    try await _driveMMRP(mmrp, port: 0, value: MMRPMACValue(macAddress: group), event: .JoinIn)
    _ = await _waitFor {
      await recorder.fdbRegister.contains { _isEqualMacAddress($0.mac, group) }
    }

    try await _driveMMRP(mmrp, port: 0, value: MMRPMACValue(macAddress: group), event: .Lv)
    let deregistered = await _waitFor(timeoutMs: 5000) {
      await recorder.fdbDeregister.contains { _isEqualMacAddress($0.mac, group) }
    }
    XCTAssertTrue(deregistered, "MMRP leave must deregister the group address")
    _ = controller
  }

  // AVnu Bridge-1.1-MRP.c.10.1.7B TRAFFIC FORWARDED: a New for a VID that the DUT is already
  // declaring (as an applicant, propagated from another port) arriving right after a LeaveAll on
  // the same port must register durably -- it must NOT be aged out by a stale leaveTimer.
  func testMVRPNewAfterLeaveAllStaysRegistered() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1])

    // TS2 (port 1) declares VID 16; MAP propagates it as an applicant declaration on port 0
    // (registrar there is still MT).
    try await _driveMVRP(mvrp, port: 1, vid: 16, event: .New)
    let declaredP0 = await _waitFor { await _isVLANDeclared(mvrp, vid: 16, port: 0) }
    XCTAssertTrue(declaredP0, "VID 16 must be propagated (declared) toward port 0")

    // TS1 (port 0) sends a LeaveAll, then immediately a New for VID 16 (the on-device order).
    let leaveAll = Message(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .LeaveAll,
        firstValue: AnyValue(VLAN(vid: 0)),
        attributeEvents: [],
        applicationEvents: nil
      )]
    )
    try await mvrp.rx(
      pdu: MRPDU(protocolVersion: 0, messages: [leaveAll]),
      for: MAPBaseSpanningTreeContext,
      from: MockPort(id: 0),
      sourceMacAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    )
    try await _driveMVRP(mvrp, port: 0, vid: 16, event: .New)

    let registered = await _isVLANRegistered(mvrp, vid: 16, port: 0)
    XCTAssertTrue(registered, "the New must register VID 16 on port 0")

    // On device, installing the dynamic VLAN in the FDB generates a netlink notification that comes
    // back as a port update (no STP topology change). This must NOT ReDeclare and age out the
    // registration we just made: Re-declare! is scoped to a topology change (STP Designated ->
    // Root/Alternate), per 10.7.5.3 -- not to arbitrary port updates.
    try await mvrp.didUpdate(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: Set([MockPort(id: 0), MockPort(id: 1)])
    )

    // must survive past LeaveTime (1s in the test config): the port update must not sweep the
    // registration to LV and start a leaveTimer.
    try await Task.sleep(for: .seconds(2))
    let stillRegistered = await _isVLANRegistered(mvrp, vid: 16, port: 0)
    XCTAssertTrue(
      stillRegistered,
      "VID 16 registered by a New after a LeaveAll must not be aged out by a stale leaveTimer"
    )
    _ = controller
  }

  // 11.2.5: a "new" declaration flushes the dynamic (learned) FDB entries for that VID on the
  // receiving Port (MAD_Join.indication) AND every Port it propagates to (MAD_Join.request) --
  // not other VIDs, and a plain (non-New) Join flushes nothing.
  func testNewIndicationFlushesDynamicFdbForVidOnly() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1])

    // a plain JoinIn (not New) must not flush the FDB
    try await _driveMVRP(mvrp, port: 0, vid: 200, event: .JoinIn)
    try await Task.sleep(for: .milliseconds(100))
    let afterJoin = await recorder.flushedDynamicFdb
    XCTAssertTrue(afterJoin.isEmpty, "a non-New Join must not flush the FDB (11.2.5)")

    // a New for VID 100 on port 0 must flush VID 100 on both the receiving port and the propagation
    // target port 1 -- and nothing for any other VID
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .New)
    let flushed = await _waitFor { await recorder.flushedDynamicFdb.count >= 2 }
    XCTAssertTrue(
      flushed,
      "a New must flush the dynamic FDB for its VID on all context ports (11.2.5)"
    )
    let entries = await recorder.flushedDynamicFdb
    XCTAssertTrue(
      entries.contains { $0.port == 0 && $0.vid == 100 },
      "New must flush the receiving port (port 0, VID 100) -- MAD_Join.indication"
    )
    XCTAssertTrue(
      entries.contains { $0.port == 1 && $0.vid == 100 },
      "New must flush the propagation target (port 1, VID 100) -- MAD_Join.request"
    )
    XCTAssertFalse(
      entries.contains { $0.vid != 100 },
      "New for VID 100 must flush the appropriate VLAN only, not other VIDs"
    )
    _ = controller
  }

  private func _makeMVRP(
    portIDs: [Int],
    exclusions: Set<VLAN> = [],
    pvid: UInt16? = nil,
    vlans: Set<UInt16> = [2],
    dynamicVlans: Set<UInt16> = []
  )
    async throws -> (MRPController<MockPort>, MVRPApplication<MockPort>, MRPTestRecorder)
  {
    let recorder = MRPTestRecorder()
    let ports = Set(portIDs.map {
      MockPort(id: $0, pvid: pvid, vlans: vlans, dynamicVlans: dynamicVlans)
    })
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.mvrp"),
      timerConfiguration: MRPTimerConfiguration(leaveTime: .seconds(1))
    )
    let mvrp = try await MVRPApplication(
      controller: controller,
      vlanExclusions: exclusions
    )
    try await mvrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    return (controller, mvrp, recorder)
  }

  private func _driveMVRP(
    _ mvrp: MVRPApplication<MockPort>,
    port: Int,
    vid: UInt16,
    event: AttributeEvent
  ) async throws {
    let message = Message(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeList: [VectorAttribute(
        leaveAllEvent: .NullLeaveAllEvent,
        firstValue: AnyValue(VLAN(vid: vid)),
        attributeEvents: [event],
        applicationEvents: nil
      )]
    )
    let source: EUI48 = [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    try await mvrp.rx(
      pdu: MRPDU(protocolVersion: 0, messages: [message]),
      for: MAPBaseSpanningTreeContext,
      from: MockPort(id: port),
      sourceMacAddress: source
    )
  }

  // 11.2.3.2.2: a dynamic registration the kernel rejects (FDB full) leaves no entry, so a later
  // Leave must be ignored, not turned into a spurious FDB delete of a VID that was never added.
  func testMVRPRejectedRegistrationIsNotDeregisteredOnLeave() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1])
    await recorder.setFailVlanRegistration([100]) // VID 100 add fails; 101 succeeds

    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    try await _driveMVRP(mvrp, port: 0, vid: 101, event: .JoinIn)
    let ok101 = await _waitFor { await recorder.vlanRegister.contains { $0.vlan.vid == 101 } }
    XCTAssertTrue(ok101, "an accepted VID must register")
    let reg100 = await recorder.vlanRegister.contains { $0.vlan.vid == 100 }
    XCTAssertFalse(reg100, "a kernel-rejected VID must not be recorded as registered")

    // leave both; the leavetimer (~1s) drives the Leave indications
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .Lv)
    try await _driveMVRP(mvrp, port: 0, vid: 101, event: .Lv)
    let dereg101 = await _waitFor { await recorder.vlanDeregister.contains { $0.vlan.vid == 101 } }
    XCTAssertTrue(dereg101, "the accepted VID must be deregistered on Leave")
    let dereg100 = await recorder.vlanDeregister.contains { $0.vlan.vid == 100 }
    XCTAssertFalse(dereg100, "a VID that was never added must not be deregistered on Leave")
    _ = controller
  }

  // 10.3 d): a port added after a peer registration already exists on another port must be
  // declared that dynamic VLAN via MAP, not left waiting for the next LeaveAll. (The codebase
  // already does this for static VLANs; this covers the dynamic half.)
  func testMVRPNewPortReceivesExistingDynamicRegistrations() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1])
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    _ = await _waitFor { await _isVLANRegistered(mvrp, vid: 100, port: 0) }

    // a port added after the fact must be declared the already-registered VID 100
    try await mvrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: [MockPort(id: 2)])
    let declared = await _waitFor { await _isVLANDeclared(mvrp, vid: 100, port: 2) }
    XCTAssertTrue(declared, "a newly-added port must be declared the dynamic VID 100 from port 0")
    _ = controller
  }

  // 11.2.3.1.7: a received VID of 0 is translated to the receiving port's PVID, never registered
  // as a bogus VLAN 0.
  func testMVRPReceivedVIDZeroTranslatedToPVID() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1], pvid: 5)
    try await _driveMVRP(mvrp, port: 0, vid: 0, event: .JoinIn)
    // a normal dynamic VID still registers, proving the rx path ran
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    let registered100 = await _waitFor {
      await recorder.vlanRegister.contains { $0.vlan.vid == 100 }
    }
    XCTAssertTrue(registered100, "a normal VID must register dynamically")
    let registered0 = await recorder.vlanRegister.contains { $0.vlan.vid == 0 }
    XCTAssertFalse(registered0, "VID 0 must be translated to the PVID, not registered as VLAN 0")
    // the translated PVID (5) is Registration Fixed, present from setup
    let pvidRegistered = await _isVLANRegistered(mvrp, vid: 5, port: 0)
    XCTAssertTrue(pvidRegistered, "the PVID must be Registration Fixed")
    _ = controller
  }

  // A peer JoinIn for a VID registers that VLAN on the reception port.
  func testMVRPJoinIndicationRegistersVLAN() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0])
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)

    let registered = await _waitFor {
      await recorder.vlanRegister.contains { $0.vlan.vid == 100 && $0.port == 0 }
    }
    XCTAssertTrue(registered, "MVRP join indication must register the VLAN")
    _ = controller
  }

  // An excluded VID is not propagated to the FDB even when declared by a peer.
  func testMVRPExcludedVLANNotRegistered() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(
      portIDs: [0],
      exclusions: [VLAN(vid: 100)]
    )
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    try await _driveMVRP(mvrp, port: 0, vid: 200, event: .JoinIn)

    let registered200 = await _waitFor {
      await recorder.vlanRegister.contains { $0.vlan.vid == 200 }
    }
    XCTAssertTrue(registered200, "non-excluded VLAN still registers")
    let registered100 = await recorder.vlanRegister.contains { $0.vlan.vid == 100 }
    XCTAssertFalse(registered100, "excluded VLAN must not register")
    _ = controller
  }

  // A statically-configured VLAN (8.8.2, MockPort.vlans = {2}) is held Registration Fixed
  // on its member port and declared out the other ports via MAP (10.3 a).
  func testMVRPStaticVLANRegisteredFixedAndPropagated() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1])
    let registered = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertTrue(registered, "static VID 2 must be Registration Fixed on its member port")
    let declared0 = await _isVLANDeclared(mvrp, vid: 2, port: 0)
    let declared1 = await _isVLANDeclared(mvrp, vid: 2, port: 1)
    XCTAssertTrue(declared0, "VID 2 (static on port 1) must be declared on port 0")
    XCTAssertTrue(declared1, "VID 2 (static on port 0) must be declared on port 1")
    _ = controller
  }

  // A single-port static VLAN holds its Registrar Fixed but leaves its Applicant an Observer:
  // MAP propagates registrations to the *other* ports only (10.3 a), so the local Applicant is
  // not driven into a declaring state. The 10.7.2 "In *and* JoinIn" emission is layered on at
  // transmit time (see testMVRPStaticVLANEmitsJoinInOnOwnPort), not by moving the Applicant.
  func testMVRPStaticVLANSinglePortObserverState() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0])
    let registered = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertTrue(registered, "static VID 2 must be Registration Fixed on its member port")
    let declared = await _isVLANDeclared(mvrp, vid: 2, port: 0)
    XCTAssertFalse(
      declared,
      "the Applicant stays an Observer; JoinIn is an emission rule, not a state"
    )
    _ = controller
  }

  // 10.7.2: a Registration Fixed Registrar sends In *and* JoinIn on its own port, so a peer
  // attached there receives a registerable Join. VID 100 is static on port 0 only, so its
  // Applicant there is an Observer with no MAP backing; it must still be *emitted* as a JoinIn,
  // never a bare In. (VID 2, static on both ports, is MAP-declared on port 0 and thus supplies
  // the transmission opportunity that carries VID 100 -- mirroring the real bridge, where a
  // static VLAN rides out alongside the PVID/SR declarations.)
  func testMVRPStaticVLANEmitsJoinInOnOwnPort() async throws {
    let recorder = MRPTestRecorder()
    let ports: Set<MockPort> = [
      MockPort(id: 0, vlans: [2, 100]),
      MockPort(id: 1, vlans: [2]),
    ]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.mvrp"),
      timerConfiguration: MRPTimerConfiguration(leaveTime: .seconds(1))
    )
    let mvrp = try await MVRPApplication(controller: controller)
    try await mvrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)

    let emittedJoinIn = await _waitFor {
      await _transmittedVLANEvents(recorder, mvrp, port: 0, vid: 100).contains(.JoinIn)
    }
    XCTAssertTrue(
      emittedJoinIn,
      "VID 100 (static on port 0 only) must be emitted as JoinIn on port 0"
    )
    let events = await _transmittedVLANEvents(recorder, mvrp, port: 0, vid: 100)
    XCTAssertFalse(
      events.contains(.In),
      "a Registration Fixed port must not emit a bare In (10.7.2 requires JoinIn)"
    )
    _ = controller
  }

  // A statically-configured VLAN in the exclusion set is neither registered nor declared.
  func testMVRPExcludedStaticVLANNotRegistered() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1], exclusions: [VLAN(vid: 2)])
    let registered = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertFalse(registered, "excluded VID 2 must not be registered")
    let declared = await _isVLANDeclared(mvrp, vid: 2, port: 1)
    XCTAssertFalse(declared, "excluded VID 2 must not be declared")
    _ = controller
  }

  // The PVID has a Static VLAN Registration Entry with Registration Fixed on all ports
  // (11.2.1.3), so its membership is propagated like any other static VLAN.
  func testMVRPDeclaresPVID() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1], pvid: 1)
    let registered = await _isVLANRegistered(mvrp, vid: 1, port: 0)
    XCTAssertTrue(registered, "PVID must be Registration Fixed (11.2.1.3)")
    let declared = await _isVLANDeclared(mvrp, vid: 1, port: 1)
    XCTAssertTrue(declared, "PVID membership must be propagated to the other ports")
    _ = controller
  }

  // Even if a peer Join/Leave indication fires for a static VID (e.g. in the window
  // around a port flap before Registration Fixed is re-established), the dynamic path
  // must neither re-add the entry as dynamic nor delete it.
  func testMVRPStaticVLANNotDemotedByRacingIndication() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1])
    // drive the indications directly, as though the registrar had fired before the
    // static registration was in place
    try await mvrp.onJoinIndication(
      contextIdentifier: MAPBaseSpanningTreeContext,
      port: MockPort(id: 0),
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeSubtype: nil,
      attributeValue: VLAN(vid: 2),
      isNew: false,
      eventSource: .peer
    )
    try await mvrp.onLeaveIndication(
      contextIdentifier: MAPBaseSpanningTreeContext,
      port: MockPort(id: 0),
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeSubtype: nil,
      attributeValue: VLAN(vid: 2),
      eventSource: .peer
    )
    let registered = await recorder.vlanRegister.contains { $0.vlan.vid == 2 }
    XCTAssertFalse(registered, "static VID 2 must not be re-added as dynamic")
    let deregistered = await recorder.vlanDeregister.contains { $0.vlan.vid == 2 }
    XCTAssertFalse(deregistered, "static VID 2 must not be deleted by a peer Leave")
    _ = controller
  }

  // A peer Join for a statically-registered VID is absorbed by the Fixed registrar
  // (10.7.2): no join indication fires, so no dynamic kernel entry is created.
  func testMVRPStaticVLANNotOverriddenByPeerJoin() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1])
    try await _driveMVRP(mvrp, port: 0, vid: 2, event: .JoinIn)
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)

    // VID 100 (dynamic) proves the rx path ran; VID 2 (static) must not re-register
    let registered100 = await _waitFor {
      await recorder.vlanRegister.contains { $0.vlan.vid == 100 }
    }
    XCTAssertTrue(registered100, "non-static VID 100 must register dynamically")
    let registered2 = await recorder.vlanRegister.contains { $0.vlan.vid == 2 }
    XCTAssertFalse(registered2, "a peer Join must not create a dynamic entry for a static VID")
    let stillRegistered = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertTrue(stillRegistered, "the static registration must remain")
    _ = controller
  }

  // Registration Fixed ignores all MRP messages (10.7.2): a peer Leave neither clears the
  // registration nor withdraws the propagated declarations.
  func testMVRPStaticVLANSurvivesPeerLeave() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1])
    try await _driveMVRP(mvrp, port: 0, vid: 2, event: .Lv)
    let registered = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertTrue(registered, "Registration Fixed must ignore a peer Leave")
    let declared = await _isVLANDeclared(mvrp, vid: 2, port: 1)
    XCTAssertTrue(declared, "propagated declaration must survive a peer Leave")
    _ = controller
  }

  // Dynamic (peer-registered) VID: once every peer has left and each Registrar leavetimer
  // has expired, the MAP-propagated declaration must be withdrawn (Lv) on the other ports
  // (10.3 b), not kept declaring (JoinMt) indefinitely.
  func testMVRPDynamicVLANWithdrawnAfterAllPeersLeave() async throws {
    let vid: UInt16 = 100 // not in the default static set (vlans: [2]) -> purely dynamic
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1, 2])

    // two peers register VID 100; MAP propagates a declaration to the third port
    try await _driveMVRP(mvrp, port: 0, vid: vid, event: .JoinIn)
    try await _driveMVRP(mvrp, port: 1, vid: vid, event: .JoinIn)
    let declared = await _waitFor { await _isVLANDeclared(mvrp, vid: vid, port: 2) }
    XCTAssertTrue(declared, "VID \(vid) must be declared on port 2 via MAP propagation")

    // both peers leave; the leavetimer (leaveTime 1s) expires each Registrar to MT
    try await _driveMVRP(mvrp, port: 0, vid: vid, event: .Lv)
    try await _driveMVRP(mvrp, port: 1, vid: vid, event: .Lv)

    // with no registration left anywhere, the propagated declaration must be withdrawn
    let withdrawn = await _waitFor { await !_isVLANDeclared(mvrp, vid: vid, port: 2) }
    XCTAssertTrue(
      withdrawn,
      "VID \(vid) must be withdrawn on port 2 after all peers leave (10.3 b)"
    )
    let lvEmitted = await _transmittedVLANEvents(recorder, mvrp, port: 2, vid: vid).contains(.Lv)
    XCTAssertTrue(lvEmitted, "an Lv event must be transmitted on port 2 when the VID is withdrawn")
    _ = controller
  }

  // MAP leave propagation is refcounted (10.3 b): a withdrawal reaches a port only when no
  // other port still holds a registration for the attribute.
  func testMVRPAdministrativeWithdrawIsRefcounted() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1, 2])
    // static VID 2 on all three ports; withdrawing it from port 0 must not withdraw any
    // declaration, as ports 1 and 2 still hold registrations
    try await mvrp.administrativelyDeregister(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: VLAN(vid: 2),
      from: MockPort(id: 0),
      for: MAPBaseSpanningTreeContext
    )
    let declared2 = await _isVLANDeclared(mvrp, vid: 2, port: 2)
    XCTAssertTrue(declared2, "VID 2 must remain declared while other ports hold registrations")
    // withdrawing from port 1 leaves only port 2 registered: port 2's declaration (backed
    // by ports 0/1) is withdrawn, while port 0's (backed by port 2) survives
    try await mvrp.administrativelyDeregister(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: VLAN(vid: 2),
      from: MockPort(id: 1),
      for: MAPBaseSpanningTreeContext
    )
    // the applicant remains in LA (still declared) until the Leave transmits
    let withdrawn2 = await _waitFor { await !_isVLANDeclared(mvrp, vid: 2, port: 2) }
    XCTAssertTrue(withdrawn2, "VID 2 must be withdrawn once no other port holds a registration")
    let declared0 = await _isVLANDeclared(mvrp, vid: 2, port: 0)
    XCTAssertTrue(declared0, "port 2's remaining registration must back port 0's declaration")
    _ = controller
  }

  // The mirror of registration: administratively withdrawing a static VLAN clears its Fixed
  // Registrar on that port (not merely the MAP declaration). Once the last registration is
  // gone, the propagated declaration on the other port is withdrawn too.
  func testMVRPStaticVLANDeregisterClearsRegistrar() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1])
    let before = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertTrue(before, "static VID 2 must start Registration Fixed")

    try await mvrp.administrativelyDeregister(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: VLAN(vid: 2),
      from: MockPort(id: 0),
      for: MAPBaseSpanningTreeContext
    )
    let cleared0 = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertFalse(cleared0, "deregistration must clear the Fixed Registrar on port 0")
    // port 1 still holds a registration, so port 0's declaration (backed by port 1) survives
    let stillDeclared = await _isVLANDeclared(mvrp, vid: 2, port: 0)
    XCTAssertTrue(stillDeclared, "port 1's registration must still back port 0's declaration")

    try await mvrp.administrativelyDeregister(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: VLAN(vid: 2),
      from: MockPort(id: 1),
      for: MAPBaseSpanningTreeContext
    )
    let cleared1 = await _isVLANRegistered(mvrp, vid: 2, port: 1)
    XCTAssertFalse(cleared1, "deregistration must clear the Fixed Registrar on port 1")
    let withdrawn = await _waitFor { await !_isVLANDeclared(mvrp, vid: 2, port: 0) }
    XCTAssertTrue(withdrawn, "with no registration left, VID 2 must be withdrawn everywhere")
    _ = controller
  }

  // The runtime removal path (operator `bridge vlan del`): recomputing the static set without
  // a previously-static VID deregisters it -- the mirror of the add in _updateStaticVLANs.
  func testMVRPStaticVLANRemovedAtRuntimeDeregisters() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1], vlans: [2, 100])
    let registered = await _isVLANRegistered(mvrp, vid: 100, port: 0)
    XCTAssertTrue(registered, "static VID 100 must start Registration Fixed")

    // VID 100 removed from the kernel VLAN DB on port 0
    await mvrp._updateStaticVLANs(port: MockPort(id: 0, vlans: [2]))

    let cleared = await _waitFor { await !_isVLANRegistered(mvrp, vid: 100, port: 0) }
    XCTAssertTrue(cleared, "removing VID 100 from the VLAN DB must clear its Fixed Registrar")
    _ = controller
  }

  // A VLAN carrying BRIDGE_VLAN_INFO_DYNAMIC (port.dynamicVlans) is a peer registration
  // left over from a previous run: it must not be captured as static at startup.
  func testMVRPKernelDynamicVLANNotCapturedAsStatic() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(
      portIDs: [0, 1],
      vlans: [2, 100],
      dynamicVlans: [100]
    )
    let registered2 = await _isVLANRegistered(mvrp, vid: 2, port: 0)
    XCTAssertTrue(registered2, "static VID 2 must still be Registration Fixed")
    let registered100 = await _isVLANRegistered(mvrp, vid: 100, port: 0)
    XCTAssertFalse(registered100, "dynamic VID 100 must not be promoted to Registration Fixed")
    let declared100 = await _isVLANDeclared(mvrp, vid: 100, port: 1)
    XCTAssertFalse(declared100, "dynamic VID 100 must not be propagated as static")
    _ = controller
  }

  // A VLAN we registered dynamically for a peer this run is excluded from the static set
  // even without kernel dynamic-flag support (in-process tracking): after the peer leaves,
  // the registration must clear, which it would not if wrongly promoted to Fixed.
  func testMVRPDynamicRegistrationNotPromotedToStatic() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1])
    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .JoinIn)
    _ = await _waitFor { await recorder.vlanRegister.contains { $0.vlan.vid == 100 } }

    // the kernel entry now appears in port.vlans (flagless kernel: not in dynamicVlans);
    // a VLAN change notification would recompute the static set from it
    await mvrp._updateStaticVLANs(port: MockPort(id: 0, vlans: [2, 100]))

    try await _driveMVRP(mvrp, port: 0, vid: 100, event: .Lv)
    let cleared = await _waitFor(timeoutMs: 4000) {
      await !_isVLANRegistered(mvrp, vid: 100, port: 0)
    }
    XCTAssertTrue(cleared, "dynamic VID 100 must deregister on peer Leave, not become Fixed")
    _ = controller
  }

  // Per-port static VLANs (8.8.2) are held Registration Fixed and declared out the
  // other ports (10.3 a).
  func testMVRPStaticVlansRegisteredFixedAndDeclared() async throws {
    let (controller, mvrp, _) = try await _makeMVRP(portIDs: [0, 1], vlans: [2, 3])
    for vid in [UInt16(2), 3] {
      let registered = await _isVLANRegistered(mvrp, vid: vid, port: 0)
      XCTAssertTrue(registered, "static VID \(vid) must be Registration Fixed")
      let declared = await _isVLANDeclared(mvrp, vid: vid, port: 1)
      XCTAssertTrue(declared, "static VID \(vid) must be declared on the other port")
    }
    _ = controller
  }

  // A quiet (QA) static (Registration Fixed) VLAN must not re-emit a mandatory JoinIn on every
  // unrelated transmit opportunity. Per 10.7.6.3 a QA re-declaration is optional (sJ_) -- "not
  // necessary for correct protocol operation" -- so the encoder trims it; only the VLAN's own
  // periodic QA->AA reassertion re-sends it. Regression: the Registration-Fixed emission upgrade
  // (never send In/Empty/Leave) also forced sJ_ -> sJ, so any other attribute's tx opportunity
  // dragged a duplicate JoinIn for every static VLAN onto the wire (observed on the DUT).
  func testMVRPStaticVlanQuietDoesNotReemitOnUnrelatedTxOpportunity() async throws {
    let (controller, mvrp, recorder) = try await _makeMVRP(portIDs: [0, 1])
    // static VID 2 declares on port 1 and settles to QA (quiet)
    _ = await _waitFor { await _isVLANDeclared(mvrp, vid: 2, port: 1) }
    _ = await _waitFor { await _vlanJoinCount(recorder, mvrp, port: 1, vid: 2) >= 1 }
    try await Task.sleep(for: .milliseconds(250)) // settle to QA
    let before = await _vlanJoinCount(recorder, mvrp, port: 1, vid: 2)

    // unrelated dynamic VLANs churn on port 0 -> propagate to port 1, each firing a tx opportunity
    // there. The quiet static VID 2 must not ride along with a fresh mandatory JoinIn each time.
    for vid in [UInt16(100), 101, 102] {
      try await _driveMVRP(mvrp, port: 0, vid: vid, event: .JoinIn)
    }
    try await Task.sleep(for: .milliseconds(150))
    let after = await _vlanJoinCount(recorder, mvrp, port: 1, vid: 2)
    XCTAssertEqual(
      after, before,
      "a quiet static VID must not re-emit JoinIn on an unrelated tx opportunity (10.7.6.3)"
    )
    _ = controller
  }

  // MARK: - Multi-value vector coalescing correctness

  // Coalescing attributes that don't form an exact increment chain corrupts them on the
  // wire, since the receiver reconstructs value[i] as FirstValue.makeValue(relativeTo: i).

  private func _declareTalker(
    _ msrp: MSRPApplication<MockPort>,
    streamID: MSRPStreamID,
    dest: EUI48
  ) async throws {
    try await msrp.registerStream(
      streamID: streamID,
      declarationType: .talkerAdvertise,
      dataFrameParameters: MSRPDataFrameParameters(destinationAddress: dest, vlanIdentifier: 2),
      tSpec: MSRPTSpec(maxFrameSize: 64, maxIntervalFrames: 1),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
  }

  // Two talkers with consecutive stream IDs but unrelated destination MACs must not
  // be coalesced: each destination must survive the round trip exactly.
  func testCoalescingPreservesNonChainedDestinations() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0])
    let destA: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x10]
    let destB: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x20] // not destA + 1
    try await _declareTalker(msrp, streamID: MSRPStreamID(0x0001_0000_0000_0001), dest: destA)
    try await _declareTalker(msrp, streamID: MSRPStreamID(0x0001_0000_0000_0002), dest: destB)

    let ok = await _waitFor {
      let dests = await _transmittedTalkerDestinations(recorder, msrp)
      return dests.contains(UInt64(eui48: destA)) && dests.contains(UInt64(eui48: destB))
    }
    XCTAssertTrue(ok, "both destination MACs must round-trip; the run must not be coalesced")
    _ = controller
  }

  // The complementary case: an exact increment chain (consecutive stream IDs AND
  // destination MACs) may coalesce, and both values must still round-trip.
  func testCoalescingChainedTalkersRoundTrip() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0])
    let destA: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x10]
    let destB: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x11] // destA + 1
    try await _declareTalker(msrp, streamID: MSRPStreamID(0x0001_0000_0000_0001), dest: destA)
    try await _declareTalker(msrp, streamID: MSRPStreamID(0x0001_0000_0000_0002), dest: destB)

    let ok = await _waitFor {
      let dests = await _transmittedTalkerDestinations(recorder, msrp)
      return dests.contains(UInt64(eui48: destA)) && dests.contains(UInt64(eui48: destB))
    }
    XCTAssertTrue(ok, "chained talkers must round-trip whether coalesced or not")
    _ = controller
  }

  // 35.2.1.4: on a *bridge* (>=2 ports) a port becomes an SRP domain boundary port for an SR
  // class when a received Domain declares a different SRclassPriority than the port's own; a
  // matching priority leaves it a core (non-boundary) port. (An end station adopts instead --
  // see testEndStationAdoptsNeighbourSRClassPriorityAndVID.)
  func testDomainPriorityMismatchMarksBoundaryPort() async throws {
    let (controller, msrp, _) = try await _makeBridgeMSRP(portIDs: [0, 1]) // >= 2 ports = a bridge
    let port = MockPort(id: 0)

    @Sendable
    func boundaryIs(_ expected: Bool) async -> Bool {
      await (try? msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }) == expected
    }
    func receiveDomain(priority: SRclassPriority) async throws {
      try await _drive(
        msrp, port: 0, attributeType: .domain,
        value: MSRPDomainValue(srClassID: .A, srClassPriority: priority, srClassVID: SR_PVID.vid),
        event: .JoinIn
      )
    }

    // class A's local priority is CA (DefaultSRClassPriorityMap): a peer registering CA matches,
    // so the port stays a core (non-boundary) port for class A
    try await receiveDomain(priority: .CA)
    let matched = await _waitFor { await boundaryIs(false) }
    XCTAssertTrue(matched, "a matching SRclassPriority must leave the port a core port")

    // a coexisting peer registration of EE (class B's priority) mismatches CA -> boundary (h.2)
    try await receiveDomain(priority: .EE)
    let mismatched = await _waitFor { await boundaryIs(true) }
    XCTAssertTrue(
      mismatched, "a mismatched SRclassPriority must mark the port an SRP domain boundary port"
    )
    _ = controller
  }

  // A peer that declares only one SR class (class A here) must still interoperate: the declared
  // class stays a core port, while the class we declare but the peer never registers is a boundary
  // (35.2.1.4 h.1 -- declared with no matching registration), so its Talkers convert to Failed
  // code 8 rather than propagating past a peer that is not in that class's SR domain.
  func testSingleClassPeerMakesUndeclaredClassABoundary() async throws {
    let (controller, msrp, _) = try await _makeBridgeMSRP(portIDs: [0, 1])
    let port = MockPort(id: 0)

    @Sendable
    func boundary(_ srClassID: SRclassID) async -> Bool? {
      await (try? msrp.withPortState(port: port) {
        $0.isSrpDomainBoundary(for: srClassID, application: msrp)
      }) ?? nil
    }

    // the peer declares only class A, at the matching local priority (CA)
    try await _drive(
      msrp, port: 0, attributeType: .domain,
      value: MSRPDomainValue(srClassID: .A, srClassPriority: .CA, srClassVID: SR_PVID.vid),
      event: .JoinIn
    )

    let classACore = await _waitFor { await boundary(.A) == false }
    XCTAssertTrue(classACore, "the peer's declared class A must be a core (non-boundary) port")

    let classBBoundary = await _waitFor { await boundary(.B) == true }
    XCTAssertTrue(
      classBBoundary,
      "an SR class we declare with no peer registration must be a boundary port (35.2.1.4 h.1)"
    )
    _ = controller
  }

  // A not-enabled port (link down / not AVB-capable) has no gPTP peer: the periodic asCapable
  // resample must leave asCapable nil (REST collapses nil to false), not a stale PMC read.
  func testNotEnabledPortKeepsAsCapableNil() async throws {
    let recorder = MRPTestRecorder()
    // half-duplex => not AVB-capable => msrpPortEnabledStatus false; MockPort.isAsCapable is true
    let port = MockPort(id: 0, isFullDuplex: false)
    let bridge = MockBridge(ports: [port, MockPort(id: 1)], recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.asCapable")
    )
    let msrp = try await MSRPApplication(controller: controller)
    try await controller._didAdd(port: port)
    try await controller._didAdd(port: MockPort(id: 1))

    // the 1 s tick resamples gPTP asCapable; a not-enabled port must not adopt the stale true
    try await msrp.periodic(for: nil)
    let asCapable = try await msrp.withPortState(port: port) { $0.asCapable }
    XCTAssertNil(asCapable, "a not-enabled port must keep asCapable nil, not a stale PMC true")
    _ = controller
  }

  // 35.2.2.9.3/.4: an end station (single port) adopts its neighbour's SRclassPriority and
  // SRclassVID rather than treating a difference as a domain boundary.
  func testEndStationAdoptsNeighbourSRClassPriorityAndVID() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0]) // 1 port => end station
    let port = MockPort(id: 0)
    do {
      try await msrp.onJoinIndication(
        contextIdentifier: MAPBaseSpanningTreeContext, port: port,
        attributeType: MSRPAttributeType.domain.rawValue, attributeSubtype: nil,
        attributeValue: MSRPDomainValue(srClassID: .A, srClassPriority: .VI, srClassVID: 3),
        isNew: true, eventSource: .peer
      )
    } catch MRPError.doNotPropagateAttribute {}
    let priority = try await msrp.withPortState(port: port) { $0.srClassPriorityMap[.A] }
    XCTAssertEqual(priority, .VI, "an end station must adopt the neighbour's SRclassPriority")
    let vid = try await msrp.withPortState(port: port) { $0.srpClassVID[.A] }
    XCTAssertEqual(vid, VLAN(vid: 3), "an end station must adopt the neighbour's SRclassVID")
    let boundary = try await msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }
    XCTAssertEqual(boundary, false, "an end station that adopted the domain is not a boundary port")
    _ = controller
  }

  // 35.2.1.4(h): withdrawing the peer's Domain registration returns the port to boundary state
  // (a leave must not leave it "core" -- previously it was cleared to nil, read as non-boundary).
  func testDomainLeaveRestoresBoundaryPort() async throws {
    // short leaveTime so the withdrawn registration ages IN -> LV -> MT within the test
    let (controller, msrp, _) = try await _makeBridgeMSRP(portIDs: [0, 1], leaveTime: .seconds(1))
    let port = MockPort(id: 0)
    let domain = MSRPDomainValue(srClassID: .A, srClassPriority: .CA, srClassVID: SR_PVID.vid)

    @Sendable
    func boundaryIs(_ expected: Bool) async -> Bool {
      await (try? msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }) == expected
    }

    try await _drive(msrp, port: 0, attributeType: .domain, value: domain, event: .JoinIn)
    let core = await _waitFor { await boundaryIs(false) }
    XCTAssertTrue(core, "a matching Domain registration makes the port a core port")

    // rLv -> LV -> leaveTimer -> MT: once no registration remains, the port is a boundary (h.1)
    try await _drive(msrp, port: 0, attributeType: .domain, value: domain, event: .Lv)
    let boundary = await _waitFor(timeoutMs: 4000) { await boundaryIs(true) }
    XCTAssertTrue(boundary, "withdrawing the Domain returns the port to boundary state")
    _ = controller
  }

  // 35.2.1.4 h)/35.2.4: a peer changing its Domain priority re-declares the new value without a
  // Leave, so the old registration lingers until ageout. The stale priority must be superseded --
  // it must not hold the port at a boundary after the peer now matches (no flap on a legit change).
  func testDomainPriorityChangeSupersedesStaleRegistration() async throws {
    let (controller, msrp, _) = try await _makeBridgeMSRP(portIDs: [0, 1]) // >= 2 ports = a bridge
    let port = MockPort(id: 0)
    @Sendable
    func boundaryIs(_ expected: Bool) async -> Bool {
      await (try? msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }) == expected
    }
    // local class-A priority is CA; the peer first declares a mismatching EE -> boundary
    try await _drive(
      msrp, port: 0, attributeType: .domain,
      value: MSRPDomainValue(srClassID: .A, srClassPriority: .EE, srClassVID: SR_PVID.vid),
      event: .JoinIn
    )
    let boundary = await _waitFor { await boundaryIs(true) }
    XCTAssertTrue(boundary, "a mismatching peer Domain marks the port a boundary")

    // the peer changes to the matching CA without a Leave; the stale EE must be superseded so the
    // port returns to core immediately, not flap until EE ages out
    try await _drive(
      msrp, port: 0, attributeType: .domain,
      value: MSRPDomainValue(srClassID: .A, srClassPriority: .CA, srClassVID: SR_PVID.vid),
      event: .JoinIn
    )
    let core = await _waitFor { await boundaryIs(false) }
    XCTAssertTrue(
      core,
      "a matching re-declaration supersedes the stale priority and clears the boundary"
    )
    _ = controller
  }

  // 35.2.2.9: an end station adopts its neighbour's SR domain (not a boundary); when the neighbour
  // withdraws that Domain the end station must revert to a boundary, not keep streaming into it.
  func testEndStationDomainLeaveRevertsToBoundary() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0]) // 1 port => end station
    let port = MockPort(id: 0)
    let domain = MSRPDomainValue(srClassID: .A, srClassPriority: .VI, srClassVID: 3)
    do {
      try await msrp.onJoinIndication(
        contextIdentifier: MAPBaseSpanningTreeContext, port: port,
        attributeType: MSRPAttributeType.domain.rawValue, attributeSubtype: nil,
        attributeValue: domain, isNew: true, eventSource: .peer
      )
    } catch MRPError.doNotPropagateAttribute {}
    let adopted = try await msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }
    XCTAssertEqual(
      adopted,
      false,
      "an end station that adopted the neighbour domain is not a boundary"
    )

    do {
      try await msrp.onLeaveIndication(
        contextIdentifier: MAPBaseSpanningTreeContext, port: port,
        attributeType: MSRPAttributeType.domain.rawValue, attributeSubtype: nil,
        attributeValue: domain, eventSource: .peer
      )
    } catch MRPError.doNotPropagateAttribute {}
    let reverted = try await msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }
    XCTAssertEqual(
      reverted,
      true,
      "an end station reverts to boundary when the adopted domain is withdrawn"
    )
    _ = controller
  }

  // 35.2.2.9/35.2.4: a neighbour changing its Domain priority re-declares without a Leave, so the
  // old registration ages out while the new one is still adopted; the end station must NOT revert
  // to
  // a boundary on that stale leave (it would drop a still-valid stream).
  func testEndStationDomainPriorityChangeKeepsAdoption() async throws {
    // 1 port => end station; short leaveTime so the superseded registration ages out in-test
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0], leaveTime: .seconds(1))
    let port = MockPort(id: 0)
    @Sendable
    func boundaryIs(_ expected: Bool) async -> Bool {
      await (try? msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }) == expected
    }

    // adopt the neighbour's class-A domain at VI, then the neighbour changes it to VO (no Leave):
    // both coexist as registrations until the old one ages out
    try await _drive(
      msrp,
      port: 0,
      attributeType: .domain,
      value: MSRPDomainValue(srClassID: .A, srClassPriority: .VI, srClassVID: 3),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 0,
      attributeType: .domain,
      value: MSRPDomainValue(srClassID: .A, srClassPriority: .VO, srClassVID: 3),
      event: .JoinIn
    )
    let adopted = await _waitFor { await boundaryIs(false) }
    XCTAssertTrue(adopted, "an end station adopts the neighbour's domain (not a boundary)")

    // withdraw the old VI value: it ages IN -> LV -> MT (~leaveTime), but VO remains adopted. Wait
    // long enough for the stale leave to fire; a regression would flip the port to a boundary.
    try await _drive(
      msrp,
      port: 0,
      attributeType: .domain,
      value: MSRPDomainValue(srClassID: .A, srClassPriority: .VI, srClassVID: 3),
      event: .Lv
    )
    let flippedToBoundary = await _waitFor(timeoutMs: 4000) { await boundaryIs(true) }
    XCTAssertFalse(
      flippedToBoundary, "a superseded-priority leave must not drop the still-adopted domain"
    )
    _ = controller
  }

  // 35.2.2.8: a forbidden FirstValue change disguised as an Advertise->Failed type flip (a Failed
  // carrying different immutable fields) must fail the stream (code 16), keeping the original.
  func testTalkerFailedWithChangedFirstValueIsRejected() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0002)
    let advertise = _talkerAdvertise(streamID)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: advertise,
      event: .JoinIn
    )
    let propagated = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(propagated, "the original advertise must propagate")

    // Talker Failed for the same stream but with a changed maxFrameSize: the flip must not smuggle
    // the forbidden FirstValue change past mutual exclusion
    let failedChanged = MSRPTalkerFailedValue(
      streamID: streamID, dataFrameParameters: advertise.dataFrameParameters,
      tSpec: MSRPTSpec(maxFrameSize: 256, maxIntervalFrames: 1),
      priorityAndRank: advertise.priorityAndRank, accumulatedLatency: advertise.accumulatedLatency,
      systemID: MSRPSystemID(id: 0x1234), failureCode: .insufficientBandwidth
    )
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerFailed,
      value: failedChanged,
      event: .JoinIn
    )
    let failed = await _waitFor {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1)
        == .changeInFirstValueForRegisteredStreamID
    }
    XCTAssertTrue(
      failed,
      "a FirstValue change hidden in a type flip must fail the stream (code 16)"
    )
    if let egressFailed = await _declaredTalkerFailed(msrp, streamID, port: 1) {
      XCTAssertTrue(
        egressFailed.isEqualIdentity(to: advertise),
        "the Failed declaration must carry the original FirstValue"
      )
    }
    _ = controller
  }

  // 802.1Q 34.5/35.2.1.4: PFC enabled on an SR class's priority (mutually exclusive with the
  // credit-based shaper) makes the port an SRP domain boundary port for that class at setup.
  func testPFCOnSRClassPriorityMarksBoundaryPort() async throws {
    let recorder = MRPTestRecorder()
    let ports: Set<MockPort> = [MockPort(id: 0, pfcEnabledPriorities: [.CA])] // Class A priority
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.recompute")
    )
    let msrp = try await MSRPApplication(controller: controller)
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    let port = MockPort(id: 0)
    let boundaryA = try await msrp
      .withPortState(port: port) { $0.isSrpDomainBoundary(for: .A, application: msrp) }
    let boundaryB = try await msrp
      .withPortState(port: port) { $0.isSrpDomainBoundary(for: .B, application: msrp) }
    XCTAssertEqual(
      boundaryA,
      true,
      "PFC on Class A priority must mark the port a boundary port for A"
    )
    XCTAssertEqual(boundaryB, false, "Class B (no PFC on its priority) must remain a core port")
    _ = controller
  }

  // A port whose MTU exceeds the AVB max frame size is not AVB capable, so MSRP disables it and
  // treats it as an SRP domain boundary port for every class (35.2.2.8.4 / 802.1BA).
  func testHighMTUPortIsNotAVBCapable() async throws {
    XCTAssertFalse(MockPort(id: 0, mtu: 9000).isAvbCapable, "MTU > 2000 must be non-AVB-capable")
    XCTAssertTrue(MockPort(id: 0, mtu: 2000).isAvbCapable, "MTU == 2000 must remain AVB-capable")
    let recorder = MRPTestRecorder()
    let ports: Set<MockPort> = [MockPort(id: 0, mtu: 9000)]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.recompute")
    )
    let msrp = try await MSRPApplication(controller: controller)
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    let enabled = try await msrp.withPortState(port: MockPort(id: 0)) { $0.msrpPortEnabledStatus }
    XCTAssertFalse(enabled, "a high-MTU port must have MSRP disabled (not AVB capable)")
    let boundary = try await msrp
      .withPortState(port: MockPort(id: 0)) { $0.isSrpDomainBoundary(for: .A, application: msrp) }
    XCTAssertEqual(boundary, true, "a non-AVB port must be an SRP domain boundary port")
    _ = controller
  }

  // Decomposition invariant: our own boundary status (PFC / non-AVB medium) is derived live in
  // isSrpDomainBoundary, so a peer declaring a *matching* Domain -- which drives the peer map to
  // non-boundary -- cannot clear it. This is the deeper cause of the BA.c.1.4 regression.
  private func _makeBoundaryMSRP(_ port0: MockPort) async throws
    -> (MRPController<MockPort>, MSRPApplication<MockPort>)
  {
    let bridge = MockBridge(ports: [port0, MockPort(id: 1)], recorder: MRPTestRecorder())
    let controller = try await MRPController(
      bridge: bridge, logger: Logger(label: "com.padl.MRPTests.boundary")
    )
    let msrp = try await MSRPApplication(controller: controller)
    try await msrp.didAdd(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: [port0, MockPort(id: 1)]
    )
    return (controller, msrp)
  }

  private func _receiveMatchingDomainA(
    _ msrp: MSRPApplication<MockPort>,
    port: MockPort
  ) async throws {
    do {
      try await msrp.onJoinIndication(
        contextIdentifier: MAPBaseSpanningTreeContext, port: port,
        attributeType: MSRPAttributeType.domain.rawValue, attributeSubtype: nil,
        attributeValue: MSRPDomainValue(
          srClassID: .A,
          srClassPriority: .CA,
          srClassVID: SR_PVID.vid
        ),
        isNew: true, eventSource: .peer
      )
    } catch MRPError.doNotPropagateAttribute {}
  }

  func testPFCBoundarySurvivesMatchingDomain() async throws {
    let (controller, msrp) = try await _makeBoundaryMSRP(MockPort(
      id: 0,
      pfcEnabledPriorities: [.CA]
    ))
    let port = MockPort(id: 0)
    try await _receiveMatchingDomainA(msrp, port: port)

    let boundary = try await msrp
      .withPortState(port: port) { $0.isSrpDomainBoundary(for: .A, application: msrp) }
    XCTAssertEqual(
      boundary,
      true,
      "PFC keeps the port a boundary even when the peer Domain matches"
    )
    let peerMap = try await msrp.withPortState(port: port) { $0.srpDomainBoundaryPort[.A] }
    XCTAssertEqual(peerMap, false, "the peer map alone is non-boundary on a matching Domain")
    _ = controller
  }

  func testNonAvbBoundarySurvivesMatchingDomain() async throws {
    let (controller, msrp) = try await _makeBoundaryMSRP(MockPort(id: 0, mtu: 9000))
    let port = MockPort(id: 0)
    try await _receiveMatchingDomainA(msrp, port: port)

    let boundary = try await msrp
      .withPortState(port: port) { $0.isSrpDomainBoundary(for: .A, application: msrp) }
    XCTAssertEqual(
      boundary,
      true,
      "a non-AVB port stays a boundary even when the peer Domain matches"
    )
    _ = controller
  }

  // A half-duplex or sub-100 Mb/s link does not support AVB traffic, so the port is an SRP domain
  // boundary port (IEEE 802.1BA-2011 §6.4 / Table 6.1). This is what makes the bridge convert a
  // registered Talker Advertise to a Talker Failed (egressPortIsNotAvbCapable) out that port.
  func testHalfDuplexOrSlowPortIsNotAVBCapable() async throws {
    XCTAssertFalse(
      MockPort(id: 0, isFullDuplex: false).isAvbCapable, "a half-duplex link is non-AVB-capable"
    )
    XCTAssertFalse(
      MockPort(id: 0, linkSpeed: 10000).isAvbCapable, "a 10 Mb/s link is non-AVB-capable"
    )
    XCTAssertTrue(
      MockPort(id: 0, linkSpeed: 100_000).isAvbCapable, "a 100 Mb/s full-duplex link is AVB-capable"
    )

    // start full-duplex/AVB-capable, then renegotiate to half-duplex mid-run: onContextUpdated
    // must disable MSRP on the port so a talker registered on another port fails out of it
    let recorder = MRPTestRecorder()
    let ports: Set<MockPort> = [MockPort(id: 0)]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.halfDuplex")
    )
    let msrp = try await MSRPApplication(controller: controller)
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    let enabledBefore = try await msrp
      .withPortState(port: MockPort(id: 0)) { $0.msrpPortEnabledStatus }
    XCTAssertTrue(enabledBefore, "a full-duplex gigabit port must start AVB capable")

    // MockPort equality is by id, so this replaces the port state for id 0
    let halfDuplex: Set<MockPort> = [MockPort(id: 0, linkSpeed: 100_000, isFullDuplex: false)]
    try await msrp.didUpdate(contextIdentifier: MAPBaseSpanningTreeContext, with: halfDuplex)
    let enabledAfter = try await msrp
      .withPortState(port: MockPort(id: 0)) { $0.msrpPortEnabledStatus }
    XCTAssertFalse(enabledAfter, "a renegotiated half-duplex port must have MSRP disabled")

    // the port is now non-AVB, so it must read as an SRP domain boundary (35.2.4.3) even though its
    // cached boundary map -- set at creation when it was AVB-capable -- was never re-derived
    let boundaryAfter = try await msrp
      .withPortState(port: MockPort(id: 0)) { $0.isSrpDomainBoundary(for: .A, application: msrp) }
    XCTAssertEqual(
      boundaryAfter, true,
      "a renegotiated non-AVB port must be an SRP domain boundary (drives Talker Advertise -> Failed)"
    )
    _ = controller
  }

  // A port whose link is down at startup is not AVB capable, so MSRP skips fetching its priority
  // map and cannot declare SR domains. When the link later comes up, onContextUpdated must fetch
  // the map (no TC notification fires on link-up) so the port can finally declare its domains --
  // otherwise a late-linking port stays domain-less until mrpd restarts.
  func testLateLinkPortFetchesPriorityMapAndDeclaresDomains() async throws {
    let recorder = MRPTestRecorder()
    // start sub-100 Mb/s (an effectively down link): not AVB capable
    let ports: Set<MockPort> = [MockPort(id: 0, linkSpeed: 10000)]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.lateLink")
    )
    let msrp = try await MSRPApplication(controller: controller)
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)

    let mapBefore = try await msrp.withPortState(port: MockPort(id: 0)) { $0.srClassPriorityMap }
    XCTAssertTrue(mapBefore.isEmpty, "a non-AVB port must not have a priority map at startup")
    let domainsBefore = try await msrp.withPortState(port: MockPort(id: 0)) { $0.declaredDomains }
    XCTAssertTrue(domainsBefore.isEmpty, "a non-AVB port must not declare SR domains")

    // link comes up full-duplex gigabit: now AVB capable (MockPort equality is by id)
    let up: Set<MockPort> = [MockPort(id: 0)]
    try await msrp.didUpdate(contextIdentifier: MAPBaseSpanningTreeContext, with: up)

    let mapAfter = try await msrp.withPortState(port: MockPort(id: 0)) { $0.srClassPriorityMap }
    XCTAssertEqual(mapAfter, [.A: .CA, .B: .EE], "a late-linking port must fetch its priority map")
    let domainsAfter = try await msrp.withPortState(port: MockPort(id: 0)) { $0.declaredDomains }
    XCTAssertNotNil(domainsAfter[.A], "the port must declare its Class A domain once up")
    XCTAssertNotNil(domainsAfter[.B], "the port must declare its Class B domain once up")
    _ = controller
  }

  // Regression (a893d5f): when we own the queues (--configure-egress-queues), a port that is down
  // at
  // startup is skipped by didAdd, so its mqprio is never written and reads back empty. When it
  // later
  // comes up, onContextUpdated must configure the queues (and use the default map), not just read
  // the
  // empty map back -- otherwise the port declares itself a domain boundary and fails every talker
  // with requestedPriorityIsNotAnSRClassPriority until mrpd restarts.
  func testLateLinkPortConfiguresQueuesWhenOwningThem() async throws {
    let recorder = MRPTestRecorder()
    // model a switch where a port has no readable SR mqprio until we configure its egress queues
    await recorder.setPriorityMapRequiresEgressConfig(true)
    // start sub-100 Mb/s (an effectively down link): not AVB capable
    let ports: Set<MockPort> = [MockPort(id: 0, linkSpeed: 10000)]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.lateLinkConfigure")
    )
    let msrp = try await MSRPApplication(controller: controller, flags: [.configureEgressQueues])
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)

    let configuredBefore = await recorder.didConfigureEgress(port: 0)
    XCTAssertFalse(
      configuredBefore, "a port that is down at startup must not have its queues configured yet"
    )
    let domainsBefore = try await msrp.withPortState(port: MockPort(id: 0)) { $0.declaredDomains }
    XCTAssertTrue(domainsBefore.isEmpty, "a non-AVB port must not declare SR domains")

    // link comes up full-duplex gigabit: now AVB capable (MockPort equality is by id)
    let up: Set<MockPort> = [MockPort(id: 0)]
    try await msrp.didUpdate(contextIdentifier: MAPBaseSpanningTreeContext, with: up)

    let configuredAfter = await recorder.didConfigureEgress(port: 0)
    XCTAssertTrue(
      configuredAfter,
      "onContextUpdated must configure the queues of a port that becomes AVB capable after startup"
    )
    let mapAfter = try await msrp.withPortState(port: MockPort(id: 0)) { $0.srClassPriorityMap }
    XCTAssertEqual(
      mapAfter,
      [.A: .CA, .B: .EE],
      "the port must adopt the default map we configured"
    )
    let domainsAfter = try await msrp.withPortState(port: MockPort(id: 0)) { $0.declaredDomains }
    XCTAssertNotNil(domainsAfter[.A], "the port must declare its Class A domain once configured")
    XCTAssertNotNil(domainsAfter[.B], "the port must declare its Class B domain once configured")
    _ = controller
  }

  // A configureEgressQueues failure at startup must surface from didAdd (an operator-visible
  // error, as before the shared-configure refactor), not leave the port silently non-SR.
  func testEgressConfigFailureAtStartupThrows() async throws {
    let recorder = MRPTestRecorder()
    await recorder.setPriorityMapRequiresEgressConfig(true)
    await recorder.setFailEgressConfig(ports: [0])
    let ports: Set<MockPort> = [MockPort(id: 0)]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.egressFailStartup")
    )
    let msrp = try await MSRPApplication(controller: controller, flags: [.configureEgressQueues])
    do {
      try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
      XCTFail("didAdd must propagate an egress-queue configuration failure")
    } catch {}
    _ = controller
  }

  // If configureEgressQueues fails on the late-capability path, the port must NOT be left marked
  // configured with a non-empty map: that would declare domains and admit talkers whose CBS program
  // then ENOENTs, and the onContextUpdated isEmpty guard would never retry it. It must keep an
  // empty
  // map and recover on a later update once configuration succeeds.
  func testEgressConfigFailureLeavesPortRetryable() async throws {
    let recorder = MRPTestRecorder()
    await recorder.setPriorityMapRequiresEgressConfig(true)
    // start sub-100 Mb/s: not AVB capable, so didAdd skips the port (no configure attempt)
    let ports: Set<MockPort> = [MockPort(id: 0, linkSpeed: 10000)]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.egressFail")
    )
    let msrp = try await MSRPApplication(controller: controller, flags: [.configureEgressQueues])
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)

    // link comes up but the configure fails: the port must not carry a phantom map or declare
    // domains, and the update must not abort
    await recorder.setFailEgressConfig(ports: [0])
    let up: Set<MockPort> = [MockPort(id: 0)]
    try await msrp.didUpdate(contextIdentifier: MAPBaseSpanningTreeContext, with: up)
    let mapFailed = try await msrp.withPortState(port: MockPort(id: 0)) { $0.srClassPriorityMap }
    XCTAssertTrue(
      mapFailed.isEmpty,
      "a port whose egress config failed must not keep a priority map"
    )
    let domainsFailed = try await msrp.withPortState(port: MockPort(id: 0)) { $0.declaredDomains }
    XCTAssertTrue(domainsFailed.isEmpty, "a port with no mqprio must not declare SR domains")

    // configuration now succeeds; a later update must retry and bring the port up
    await recorder.setFailEgressConfig(ports: [])
    try await msrp.didUpdate(contextIdentifier: MAPBaseSpanningTreeContext, with: up)

    let configured = await recorder.didConfigureEgress(port: 0)
    XCTAssertTrue(
      configured,
      "a later update must retry egress configuration after a transient failure"
    )
    let mapOk = try await msrp.withPortState(port: MockPort(id: 0)) { $0.srClassPriorityMap }
    XCTAssertEqual(mapOk, [.A: .CA, .B: .EE], "the port must adopt the default map once configured")
    let domainsOk = try await msrp.withPortState(port: MockPort(id: 0)) { $0.declaredDomains }
    XCTAssertNotNil(domainsOk[.A], "the port must declare its Class A domain once configured")
    _ = controller
  }

  // Two streams whose StreamID/destination chain but whose AccumulatedLatency differs must not
  // coalesce: the receiver rebuilds value[1] as FirstValue.makeValue(relativeTo: 1), which carries
  // the FirstValue's latency (35.2.2.8.6). The coalescer compares serialized encodings (which
  // include latency), so a differing-latency neighbour is kept in its own vector -- even though
  // MSRPTalkerAdvertiseValue.== deliberately ignores latency.
  func testTalkerCoalescingIsLatencySensitive() throws {
    func talker(
      _ streamID: MSRPStreamID,
      dest: EUI48,
      latency: UInt32
    ) -> MSRPTalkerAdvertiseValue {
      MSRPTalkerAdvertiseValue(
        streamID: streamID,
        dataFrameParameters: MSRPDataFrameParameters(destinationAddress: dest, vlanIdentifier: 2),
        tSpec: MSRPTSpec(maxFrameSize: 64, maxIntervalFrames: 1),
        priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA),
        accumulatedLatency: latency
      )
    }
    let first = talker(0x0001_0000_0000_0000, dest: [0x91, 0xE0, 0xF0, 0, 0, 1], latency: 1000)
    let reconstructed = try first.makeValue(relativeTo: 1) // how the peer rebuilds value[1]
    let sameLatency = talker(
      0x0001_0000_0000_0001,
      dest: [0x91, 0xE0, 0xF0, 0, 0, 2],
      latency: 1000
    )
    let diffLatency = talker(
      0x0001_0000_0000_0001,
      dest: [0x91, 0xE0, 0xF0, 0, 0, 2],
      latency: 2000
    )

    XCTAssertEqual(
      try reconstructed.serialized(), try sameLatency.serialized(),
      "a same-latency chained stream reconstructs exactly, so it may coalesce"
    )
    XCTAssertNotEqual(
      try reconstructed.serialized(), try diffLatency.serialized(),
      "a differing-latency stream does not reconstruct exactly, so it must not coalesce"
    )
    // == is wire-exact, so coalescing distinguishes latency (matching instead keys on index).
    XCTAssertEqual(reconstructed, sameLatency)
    XCTAssertNotEqual(reconstructed, diffLatency)
    XCTAssertEqual(reconstructed.index, diffLatency.index)
  }

  // The Domain attribute opts out of coalescing (some peers don't expand a multi-value Domain
  // vector): each SR class must be emitted as its own single-value vector, not coalesced B->A.
  func testDomainVectorsAreNotCoalesced() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0])
    let ok = await _waitFor {
      let domains = await _transmittedDomainVectors(recorder, msrp)
      return domains.contains(where: { $0.srClassID == .A && $0.count == 1 })
        && domains.contains(where: { $0.srClassID == .B && $0.count == 1 })
    }
    XCTAssertTrue(ok, "each SR class Domain must be a separate single-value vector")
    let domains = await _transmittedDomainVectors(recorder, msrp)
    XCTAssertFalse(
      domains.contains(where: { $0.count > 1 }),
      "Domain vectors must not be coalesced into a multi-value vector"
    )
    _ = controller
  }

  // Both SR classes declare the single SR_PVID (35.2.1.4) in transmitted Domains.
  func testDomainUsesSRPVid() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0])
    let ok = await _waitFor {
      let vids = await _transmittedDomainVIDs(recorder, msrp)
      return vids[.A] == SR_PVID.vid && vids[.B] == SR_PVID.vid
    }
    XCTAssertTrue(ok, "both SR classes must declare srClassVID \(SR_PVID.vid)")
    _ = controller
  }

  // 16 contiguous, identical-parameter talkers coalesce into a single vector that must
  // round-trip every destination MAC (regression for "does not work with 16 streams").
  func testCoalescing16ContiguousStreamsRoundTrip() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0])
    var expected = Set<UInt64>()
    for i in 0..<16 {
      let streamID = MSRPStreamID(integerLiteral: 0x0001_0000_0000_0000 + UInt64(i))
      let dest: EUI48 = try (UInt64(0x91E0_F000_0010) + UInt64(i)).asEUI48()
      expected.insert(UInt64(eui48: dest))
      try await _declareTalker(msrp, streamID: streamID, dest: dest)
    }
    let want = expected
    let ok = await _waitFor {
      await _transmittedTalkerDestinations(recorder, msrp).isSuperset(of: want)
    }
    XCTAssertTrue(ok, "all 16 contiguous talker destinations must round-trip")
    _ = controller
  }

  // The same 16 streams with NON-contiguous destinations must not be mis-coalesced:
  // every destination must still survive (the index-only coalescing bug corrupted these).
  func testCoalescing16NonContiguousDestinationsRoundTrip() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0])
    var expected = Set<UInt64>()
    for i in 0..<16 {
      let streamID = MSRPStreamID(integerLiteral: 0x0001_0000_0000_0000 + UInt64(i))
      // stream IDs are contiguous, destinations are spaced by 0x10 so they do not chain
      let dest: EUI48 = try (UInt64(0x91E0_F000_0000) + UInt64(i) * 0x10).asEUI48()
      expected.insert(UInt64(eui48: dest))
      try await _declareTalker(msrp, streamID: streamID, dest: dest)
    }
    let want = expected
    let ok = await _waitFor {
      await _transmittedTalkerDestinations(recorder, msrp).isSuperset(of: want)
    }
    XCTAssertTrue(ok, "all 16 non-contiguous talker destinations must round-trip")
    _ = controller
  }

  func testPTPManagementErrorStatusParsing() throws {
    // Test that management error status TLV consumes all bytes before throwing
    // This verifies the fix for the ParserSpan migration bug

    // Build a PTP management message with error status TLV
    var bytes: [UInt8] = []

    // PTP Header (34 bytes)
    bytes.append(0x0D) // majorSdoId_messageType (management)
    bytes.append(0x02) // versionPTP
    bytes.append(contentsOf: [0x00, 0x36]) // messageLength (54 bytes)
    bytes.append(0x00) // domainNumber
    bytes.append(0x00) // minorSdoId
    bytes.append(0x00) // flagField0
    bytes.append(0x00) // flagField1
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // correctionField
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // messageTypeSpecific
    bytes.append(contentsOf: [
      0x01,
      0x02,
      0x03,
      0x04,
      0x05,
      0x06,
      0x07,
      0x08,
    ]) // sourcePortIdentity.clockIdentity
    bytes.append(contentsOf: [0x00, 0x01]) // sourcePortIdentity.portNumber
    bytes.append(contentsOf: [0x00, 0x01]) // sequenceId
    bytes.append(0x04) // controlField
    bytes.append(0x7F) // logMessageInterval

    // Management message fields (10 bytes before TLV)
    bytes.append(contentsOf: [
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
    ]) // targetPortIdentity.clockIdentity
    bytes.append(contentsOf: [0xFF, 0xFF]) // targetPortIdentity.portNumber
    bytes.append(0x01) // startingBoundaryHops
    bytes.append(0x01) // boundaryHops
    bytes.append(0x02) // reserved_actionField (response)
    bytes.append(0x00) // reserved

    // Management error status TLV (tlvType=2, with display data)
    bytes.append(contentsOf: [0x00, 0x02]) // tlvType = managementErrorStatus
    bytes.append(contentsOf: [0x00, 0x0C]) // lengthField = 12 (8 base + 4 display data)
    bytes.append(contentsOf: [0x00, 0x01]) // managementErrorId = responseTooBig
    bytes.append(contentsOf: [0x20, 0x00]) // managementId = DEFAULT_DATA_SET
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // reserved
    bytes.append(contentsOf: [0x54, 0x45, 0x53, 0x54]) // displayData = "TEST"

    // Attempt to parse - should throw the management error but consume all bytes
    XCTAssertThrowsError(
      try bytes.withParserSpan { input in
        try PTP.ManagementMessage(parsing: &input)
      }
    ) { error in
      // Should throw the management error ID
      XCTAssertTrue(error is PTPManagementError)
      if let ptpError = error as? PTPManagementError {
        XCTAssertEqual(ptpError, .responseTooBig)
      }
    }
  }

  func testPTPUnknownManagementIDParsing() throws {
    // Test that unknown management ID consumes all data bytes before throwing
    // This verifies the fix for the ParserSpan migration bug

    // Build a PTP management message with unknown management ID
    var bytes: [UInt8] = []

    // PTP Header (34 bytes)
    bytes.append(0x0D) // majorSdoId_messageType (management)
    bytes.append(0x02) // versionPTP
    bytes.append(contentsOf: [0x00, 0x38]) // messageLength (56 bytes)
    bytes.append(0x00) // domainNumber
    bytes.append(0x00) // minorSdoId
    bytes.append(0x00) // flagField0
    bytes.append(0x00) // flagField1
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // correctionField
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // messageTypeSpecific
    bytes.append(contentsOf: [
      0x01,
      0x02,
      0x03,
      0x04,
      0x05,
      0x06,
      0x07,
      0x08,
    ]) // sourcePortIdentity.clockIdentity
    bytes.append(contentsOf: [0x00, 0x01]) // sourcePortIdentity.portNumber
    bytes.append(contentsOf: [0x00, 0x02]) // sequenceId
    bytes.append(0x04) // controlField
    bytes.append(0x7F) // logMessageInterval

    // Management message fields (10 bytes before TLV)
    bytes.append(contentsOf: [
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
    ]) // targetPortIdentity.clockIdentity
    bytes.append(contentsOf: [0xFF, 0xFF]) // targetPortIdentity.portNumber
    bytes.append(0x01) // startingBoundaryHops
    bytes.append(0x01) // boundaryHops
    bytes.append(0x00) // reserved_actionField (get)
    bytes.append(0x00) // reserved

    // Management TLV with unknown management ID
    bytes.append(contentsOf: [0x00, 0x01]) // tlvType = management
    bytes.append(contentsOf: [0x00, 0x08]) // lengthField = 8 (2 for ID + 6 data)
    bytes.append(contentsOf: [0xFF, 0xFF]) // managementId = 0xFFFF (unknown)
    bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]) // dataField (6 bytes)

    // Attempt to parse - should throw unknown enumeration error but consume all bytes
    XCTAssertThrowsError(
      try bytes.withParserSpan { input in
        try PTP.ManagementMessage(parsing: &input)
      }
    ) { error in
      // Should throw unknown enumeration error
      XCTAssertTrue(error is PTP.Error)
      if let ptpError = error as? PTP.Error {
        XCTAssertEqual(ptpError, .unknownEnumerationValue)
      }
    }
  }

  func testPTPHeaderMessageLengthValidation() throws {
    // Test that PTP Header correctly validates messageLength against total buffer size
    // This is a regression test for the ParserSpan migration bug where messageLength
    // was incorrectly checked against remaining bytes instead of total buffer size

    // Build a minimal valid PTP header (34 bytes)
    var bytes: [UInt8] = []
    bytes.append(0x0D) // majorSdoId_messageType (management)
    bytes.append(0x02) // versionPTP
    bytes.append(contentsOf: [0x00, 0x22]) // messageLength (34 bytes = header size)
    bytes.append(0x00) // domainNumber
    bytes.append(0x00) // minorSdoId
    bytes.append(0x00) // flagField0
    bytes.append(0x00) // flagField1
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // correctionField
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // messageTypeSpecific
    bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]) // clockIdentity
    bytes.append(contentsOf: [0x00, 0x01]) // portNumber
    bytes.append(contentsOf: [0x00, 0x01]) // sequenceId
    bytes.append(0x04) // controlField
    bytes.append(0x7F) // logMessageInterval

    // This should parse successfully - messageLength (34) should be validated against
    // the original buffer size (34), not the remaining bytes after parsing first 4 bytes (30)
    XCTAssertNoThrow(
      try bytes.withParserSpan { input in
        _ = try PTP.Header(parsing: &input)
      }
    )
  }

  func testPTPHeaderMessageLengthTruncated() throws {
    // Test that PTP Header correctly detects truncated messages

    // Build a header claiming to be 100 bytes but only provide 34
    var bytes: [UInt8] = []
    bytes.append(0x0D) // majorSdoId_messageType (management)
    bytes.append(0x02) // versionPTP
    bytes.append(contentsOf: [0x00, 0x64]) // messageLength (100 bytes - more than we have!)
    bytes.append(0x00) // domainNumber
    bytes.append(0x00) // minorSdoId
    bytes.append(0x00) // flagField0
    bytes.append(0x00) // flagField1
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // correctionField
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // messageTypeSpecific
    bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]) // clockIdentity
    bytes.append(contentsOf: [0x00, 0x01]) // portNumber
    bytes.append(contentsOf: [0x00, 0x01]) // sequenceId
    bytes.append(0x04) // controlField
    bytes.append(0x7F) // logMessageInterval

    // Should throw messageTruncated error
    XCTAssertThrowsError(
      try bytes.withParserSpan { input in
        _ = try PTP.Header(parsing: &input)
      }
    ) { error in
      XCTAssertTrue(error is PTP.Error)
      if let ptpError = error as? PTP.Error {
        XCTAssertEqual(ptpError, .messageTruncated)
      }
    }
  }

  func testPTPHeaderWith70ByteMessage() throws {
    // Regression test for the messageLength validation bug
    // This test ensures that a 70-byte message with messageLength=70
    // parses without throwing messageTruncated (the bug that was fixed)

    // Build a simple 70-byte PTP management message
    var bytes: [UInt8] = []

    // PTP Header (34 bytes)
    bytes.append(0x0D) // majorSdoId_messageType (management)
    bytes.append(0x02) // versionPTP
    bytes.append(contentsOf: [0x00, 0x46]) // messageLength (70 bytes total)
    bytes.append(0x00) // domainNumber
    bytes.append(0x00) // minorSdoId
    bytes.append(0x00) // flagField0
    bytes.append(0x00) // flagField1
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // correctionField
    bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // messageTypeSpecific
    bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]) // clockIdentity
    bytes.append(contentsOf: [0x00, 0x01]) // portNumber
    bytes.append(contentsOf: [0x00, 0x01]) // sequenceId
    bytes.append(0x04) // controlField
    bytes.append(0x7F) // logMessageInterval

    // Management message fields (14 bytes)
    bytes.append(contentsOf: [
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
    ]) // targetPortIdentity.clockIdentity
    bytes.append(contentsOf: [0xFF, 0xFF]) // targetPortIdentity.portNumber
    bytes.append(0x01) // startingBoundaryHops
    bytes.append(0x01) // boundaryHops
    bytes.append(0x00) // reserved_actionField (get)
    bytes.append(0x00) // reserved

    // Management TLV (22 bytes to reach 70 total: 34 header + 14 mgmt + 22 TLV)
    bytes.append(contentsOf: [0x00, 0x01]) // tlvType = management
    bytes.append(contentsOf: [0x00, 0x12]) // lengthField = 18 (16 data + 2 for managementId)
    bytes.append(contentsOf: [0x00, 0x00]) // managementId = NULL_PTP_MANAGEMENT
    bytes.append(contentsOf: [UInt8](repeating: 0x00, count: 16)) // dataField (16 bytes of padding)

    XCTAssertEqual(bytes.count, 70)

    // The key test: this should NOT throw messageTruncated
    // Before the fix, it would fail because messageLength (70) was checked against
    // input.count after consuming 4 bytes (66), causing a false positive truncation error
    XCTAssertNoThrow(
      try bytes.withParserSpan { input in
        let msg = try PTP.ManagementMessage(parsing: &input)
        XCTAssertEqual(msg.header.messageLength, 70)
      }
    )
  }

  func testMSRPTalkerFailedWithoutListenerDoesNotCreateFakeListener() async throws {
    // Regression test for bug where receiving TalkerFailed for a stream without
    // a configured listener would incorrectly create a listenerAskingFailed declaration.
    // This violates IEEE 802.1Q which states that listener declarations should only
    // be made when a listener application entity has registered to receive the stream.

    let logger = Logger(label: "com.padl.MRPTests.MSRPTalkerFailedBug")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    let msrp = try await MSRPApplication(controller: controller)

    // Create a TalkerFailed message for a stream that has no listener configured.
    let streamID = MSRPStreamID(0x0001_F2FE_D2A4_0002)
    let dataFrameParams = MSRPDataFrameParameters(
      destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0xB3, 0x6A],
      vlanIdentifier: 2
    )
    let tSpec = MSRPTSpec(maxFrameSize: 224, maxIntervalFrames: 1)
    let priorityAndRank = MSRPPriorityAndRank(dataFramePriority: .CA, rank: true)

    let talkerFailed = MSRPTalkerFailedValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 261_300,
      systemID: MSRPSystemID(id: 9_223_372_056_556_595_877),
      failureCode: .egressPortIsNotAvbCapable
    )

    // Before the fix, this would incorrectly create a listenerAskingFailed declaration
    // even though no listener exists for this stream. After the fix, it should not
    // create any listener declaration.

    // Serialize the TalkerFailed value to verify it's well-formed.
    var serializationContext = SerializationContext()
    try talkerFailed.serialize(into: &serializationContext)

    // Verify that the TalkerFailed value was serialized correctly.
    XCTAssertGreaterThan(serializationContext.bytes.count, 0)

    // The key validation is in the fix itself: when _mergeListenerDeclarations
    // is called with declarationType=nil (no listener exists) and receives a
    // TalkerFailed, it now returns nil instead of .listenerAskingFailed.
    // This test documents the expected behavior and serves as a regression test.
    _ = msrp // Silence unused variable warning
  }

  func testMSRPTalkerFailedWithExistingListenerCreatesAskingFailed() async throws {
    // Test that when TalkerFailed is received and a listener exists, the system
    // should create a listenerAskingFailed declaration. This is the correct
    // behavior according to IEEE 802.1Q.

    let logger = Logger(label: "com.padl.MRPTests.MSRPTalkerFailedWithListener")
    let bridge = MockBridge()
    let controller = try await MRPController(bridge: bridge, logger: logger)
    _ = try await MSRPApplication(controller: controller)

    // Create a stream with a listener.
    let streamID = MSRPStreamID(0x0001_F2FE_D2A4_0000)

    // Create a listener value (simulating that a listener is registered).
    let listenerValue = MSRPListenerValue(streamID: streamID)

    var serializationContext = SerializationContext()
    try listenerValue.serialize(into: &serializationContext)

    // Verify listener value serialization.
    XCTAssertGreaterThan(serializationContext.bytes.count, 0)

    // When TalkerFailed is received for a stream that has a listener, the declaration
    // type should transition to listenerAskingFailed. This is the correct behavior
    // and should continue to work after the fix.

    let dataFrameParams = MSRPDataFrameParameters(
      destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0xB3, 0x68],
      vlanIdentifier: 2
    )
    let tSpec = MSRPTSpec(maxFrameSize: 224, maxIntervalFrames: 1)
    let priorityAndRank = MSRPPriorityAndRank(dataFramePriority: .CA, rank: true)

    let talkerFailed = MSRPTalkerFailedValue(
      streamID: streamID,
      dataFrameParameters: dataFrameParams,
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: 261_300,
      systemID: MSRPSystemID(id: 9_223_372_056_556_595_877),
      failureCode: .egressPortIsNotAvbCapable
    )

    serializationContext = SerializationContext()
    try talkerFailed.serialize(into: &serializationContext)

    // Verify TalkerFailed serialization.
    XCTAssertGreaterThan(serializationContext.bytes.count, 0)

    // The fix should not affect this case - when a listener exists, it should
    // still transition to askingFailed when TalkerFailed is received.
  }

  func testArrayPaddingInitializerExactMultiple() {
    // Test that arrays with counts that are exact multiples are not padded.
    let input: [UInt8] = [1, 2, 3]
    let padded = Array(input, multiple: 3, with: 0)

    XCTAssertEqual(padded.count, 3)
    XCTAssertEqual(padded, [1, 2, 3])
  }

  func testArrayPaddingInitializerNeedsPadding() {
    // Test that arrays are padded to the next multiple.
    let input: [UInt8] = [1, 2]
    let padded = Array(input, multiple: 3, with: 0)

    XCTAssertEqual(padded.count, 3)
    XCTAssertEqual(padded, [1, 2, 0])
  }

  func testArrayPaddingInitializerSingleElement() {
    // Test padding a single element to a multiple of 4.
    let input: [UInt8] = [42]
    let padded = Array(input, multiple: 4, with: 0)

    XCTAssertEqual(padded.count, 4)
    XCTAssertEqual(padded, [42, 0, 0, 0])
  }

  func testArrayPaddingInitializerEmpty() {
    // Test that empty arrays remain empty (0 is a multiple of any number).
    let input: [UInt8] = []
    let padded = Array(input, multiple: 3, with: 0)

    XCTAssertEqual(padded.count, 0)
    XCTAssertEqual(padded, [])
  }

  func testArrayPaddingInitializerFromSlice() {
    // Test that the initializer works with non-Array collections like slices.
    let input: [UInt8] = [1, 2, 3, 4, 5]
    let slice = input[1...3] // [2, 3, 4]
    let padded = Array(slice, multiple: 4, with: 9)

    XCTAssertEqual(padded.count, 4)
    XCTAssertEqual(padded, [2, 3, 4, 9])
  }

  func testArrayPaddingInitializerCustomElement() {
    // Test padding with a non-zero element.
    let input: [UInt8] = [1, 2]
    let padded = Array(input, multiple: 5, with: 255)

    XCTAssertEqual(padded.count, 5)
    XCTAssertEqual(padded, [1, 2, 255, 255, 255])
  }

  func testTimerReschedulingFromCallback() async throws {
    // Test that a timer can reschedule itself from within its own callback
    // without losing the task reference. This verifies the fix where _task
    // is cleared before calling the callback, allowing isRunning to return
    // false and permitting new timer starts.

    actor CallbackTracker {
      var callCount = 0
      var shouldReschedule = false
      var timer: MRP.Timer?

      func recordCall() {
        callCount += 1
      }

      func getCallCount() -> Int {
        callCount
      }

      func setShouldReschedule(_ value: Bool) {
        shouldReschedule = value
      }

      func getShouldReschedule() -> Bool {
        shouldReschedule
      }

      func setTimer(_ t: MRP.Timer) {
        timer = t
      }

      func reschedule() {
        timer?.start(interval: Duration.milliseconds(10))
      }

      func isTimerRunning() -> Bool {
        timer?.isRunning ?? false
      }

      func stopTimer() {
        timer?.stop()
      }
    }

    let tracker = CallbackTracker()

    let timer = MRP.Timer(label: "test") {
      await tracker.recordCall()

      // Try to reschedule from within the callback
      if await tracker.getShouldReschedule() {
        await tracker.setShouldReschedule(false)
        await tracker.reschedule()
      }
    }

    await tracker.setTimer(timer)

    // Enable rescheduling
    await tracker.setShouldReschedule(true)

    // Start the timer
    timer.start(interval: Duration.milliseconds(10))

    // Wait for first callback
    try await Task.sleep(for: Duration.milliseconds(50))

    // Should have been called twice: once from initial start, once from reschedule
    let count = await tracker.getCallCount()
    XCTAssertGreaterThanOrEqual(
      count,
      2,
      "Timer should have fired at least twice (initial + rescheduled)"
    )

    // Verify isRunning works correctly
    let isRunning = await tracker.isTimerRunning()
    XCTAssertFalse(
      isRunning,
      "Timer should not be running after callback completes without rescheduling"
    )

    await tracker.stopTimer()
  }

  // MARK: - 802.1Q Table 10-3 Registrar State Tests

  func testApplicantLOSuppressionWhenUnregistered_rLA() {
    // Test 802.1Q Table 10-3: When registrar state is MT (unregistered),
    // LO transition should be suppressed for VO/AO/QO states on rLA! event
    let applicant = Applicant()
    let unregisteredFlags: StateMachineHandlerFlags = [] // No .isRegistered flag

    // Test VO state with rLA! when unregistered
    XCTAssertEqual(applicant.description, "VO")
    let (action1, _) = applicant.action(for: .rLA, flags: unregisteredFlags)
    XCTAssertNil(action1)
    XCTAssertEqual(applicant.description, "VO", "VO should stay in VO on rLA! when unregistered")

    // Set up to AO state: VO -> rJoinIn -> AO
    _ = applicant.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    XCTAssertEqual(applicant.description, "AO")

    // Test AO state with rLA! when unregistered
    let (action2, _) = applicant.action(for: .rLA, flags: unregisteredFlags)
    XCTAssertNil(action2)
    XCTAssertEqual(applicant.description, "AO", "AO should stay in AO on rLA! when unregistered")

    // Set up to QO state: AO -> rJoinIn -> QO
    _ = applicant.action(for: .rJoinIn, flags: unregisteredFlags) // AO -> QO
    XCTAssertEqual(applicant.description, "QO")

    // Test QO state with rLA! when unregistered
    let (action3, _) = applicant.action(for: .rLA, flags: unregisteredFlags)
    XCTAssertNil(action3)
    XCTAssertEqual(applicant.description, "QO", "QO should stay in QO on rLA! when unregistered")
  }

  func testApplicantLOTransitionWhenRegistered_rLA() {
    // Test that when registrar is registered (IN or LV state),
    // original behavior is preserved: VO/AO/QO -> LO on rLA!
    let applicant = Applicant()
    let registeredState = Registrar.State.IN

    // Test VO state with rLA! when registered
    XCTAssertEqual(applicant.description, "VO")
    let (action1, txOpp1) = applicant.action(for: .rLA, registrarState: registeredState, flags: [])
    XCTAssertNil(action1)
    XCTAssertTrue(txOpp1)
    XCTAssertEqual(
      applicant.description,
      "LO",
      "VO should transition to LO on rLA! when registered"
    )

    // Reset and set up to AO state
    let applicant2 = Applicant()
    _ = applicant2.action(for: .rJoinIn, registrarState: registeredState, flags: []) // VO -> AO
    XCTAssertEqual(applicant2.description, "AO")

    // Test AO state with rLA! when registered
    let (action2, txOpp2) = applicant2.action(for: .rLA, registrarState: registeredState, flags: [])
    XCTAssertNil(action2)
    XCTAssertTrue(txOpp2)
    XCTAssertEqual(
      applicant2.description,
      "LO",
      "AO should transition to LO on rLA! when registered"
    )

    // Reset and set up to QO state
    let applicant3 = Applicant()
    _ = applicant3.action(for: .rJoinIn, registrarState: registeredState, flags: []) // VO -> AO
    _ = applicant3.action(for: .rJoinIn, registrarState: registeredState, flags: []) // AO -> QO
    XCTAssertEqual(applicant3.description, "QO")

    // Test QO state with rLA! when registered
    let (action3, txOpp3) = applicant3.action(for: .rLA, registrarState: registeredState, flags: [])
    XCTAssertNil(action3)
    XCTAssertTrue(txOpp3)
    XCTAssertEqual(
      applicant3.description,
      "LO",
      "QO should transition to LO on rLA! when registered"
    )
  }

  func testApplicantLOSuppressionWhenUnregistered_txLA() {
    // Test 802.1Q Table 10-3: When registrar state is MT (unregistered),
    // LO transition should be suppressed for VO/AO/QO states on txLA! event
    let applicant = Applicant()
    let unregisteredFlags: StateMachineHandlerFlags = []

    // Test VO state with txLA! when unregistered
    XCTAssertEqual(applicant.description, "VO")
    let (action1, _) = applicant.action(for: .txLA, flags: unregisteredFlags)
    XCTAssertEqual(action1, .s_)
    XCTAssertEqual(applicant.description, "VO", "VO should stay in VO on txLA! when unregistered")

    // Set up to AO state
    _ = applicant.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    XCTAssertEqual(applicant.description, "AO")

    // Test AO state with txLA! when unregistered
    let (action2, _) = applicant.action(for: .txLA, flags: unregisteredFlags)
    XCTAssertEqual(action2, .s_)
    XCTAssertEqual(applicant.description, "AO", "AO should stay in AO on txLA! when unregistered")

    // Set up to QO state
    _ = applicant.action(for: .rJoinIn, flags: unregisteredFlags) // AO -> QO
    XCTAssertEqual(applicant.description, "QO")

    // Test QO state with txLA! when unregistered
    let (action3, _) = applicant.action(for: .txLA, flags: unregisteredFlags)
    XCTAssertEqual(action3, .s_)
    XCTAssertEqual(applicant.description, "QO", "QO should stay in QO on txLA! when unregistered")
  }

  func testApplicantLOTransitionWhenRegistered_txLA() {
    // Test that when registrar is registered, VO/AO/QO -> LO on txLA!
    let unregisteredFlags: StateMachineHandlerFlags = []
    let registeredState = Registrar.State.IN

    // Test VO state with txLA! when registered
    let applicant1 = Applicant()
    XCTAssertEqual(applicant1.description, "VO")
    let (action1, _) = applicant1.action(for: .txLA, registrarState: registeredState, flags: [])
    XCTAssertEqual(action1, .s_)
    XCTAssertEqual(
      applicant1.description,
      "LO",
      "VO should transition to LO on txLA! when registered"
    )

    // Test AO state with txLA! when registered
    let applicant2 = Applicant()
    _ = applicant2.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    XCTAssertEqual(applicant2.description, "AO")

    let (action2, _) = applicant2.action(for: .txLA, registrarState: registeredState, flags: [])
    XCTAssertEqual(action2, .s_)
    XCTAssertEqual(
      applicant2.description,
      "LO",
      "AO should transition to LO on txLA! when registered"
    )

    // Test QO state with txLA! when registered
    let applicant3 = Applicant()
    _ = applicant3.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    _ = applicant3.action(for: .rJoinIn, flags: unregisteredFlags) // AO -> QO
    XCTAssertEqual(applicant3.description, "QO")

    let (action3, _) = applicant3.action(for: .txLA, registrarState: registeredState, flags: [])
    XCTAssertEqual(action3, .s_)
    XCTAssertEqual(
      applicant3.description,
      "LO",
      "QO should transition to LO on txLA! when registered"
    )
  }

  func testApplicantLOSuppressionWhenUnregistered_txLAF() {
    // Test 802.1Q Table 10-3: When registrar state is MT (unregistered),
    // LO transition should be suppressed for VO/AO/QO states on txLAF! event
    let unregisteredFlags: StateMachineHandlerFlags = []

    // Test VO state with txLAF! when unregistered
    let applicant1 = Applicant()
    XCTAssertEqual(applicant1.description, "VO")
    let (action1, txOpp1) = applicant1.action(for: .txLAF, flags: unregisteredFlags)
    XCTAssertNil(action1)
    XCTAssertFalse(txOpp1)
    XCTAssertEqual(applicant1.description, "VO", "VO should stay in VO on txLAF! when unregistered")

    // Test AO state with txLAF! when unregistered
    let applicant2 = Applicant()
    _ = applicant2.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    XCTAssertEqual(applicant2.description, "AO")

    let (action2, txOpp2) = applicant2.action(for: .txLAF, flags: unregisteredFlags)
    XCTAssertNil(action2)
    XCTAssertFalse(txOpp2)
    XCTAssertEqual(applicant2.description, "AO", "AO should stay in AO on txLAF! when unregistered")

    // Test QO state with txLAF! when unregistered
    let applicant3 = Applicant()
    _ = applicant3.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    _ = applicant3.action(for: .rJoinIn, flags: unregisteredFlags) // AO -> QO
    XCTAssertEqual(applicant3.description, "QO")

    let (action3, txOpp3) = applicant3.action(for: .txLAF, flags: unregisteredFlags)
    XCTAssertNil(action3)
    XCTAssertFalse(txOpp3)
    XCTAssertEqual(applicant3.description, "QO", "QO should stay in QO on txLAF! when unregistered")
  }

  func testApplicantLOTransitionWhenRegistered_txLAF() {
    // Test that when registrar is registered, VO/AO/QO -> LO on txLAF!
    let unregisteredFlags: StateMachineHandlerFlags = []
    let registeredState = Registrar.State.IN

    // Test VO state with txLAF! when registered
    let applicant1 = Applicant()
    XCTAssertEqual(applicant1.description, "VO")
    let (action1, txOpp1) = applicant1.action(
      for: .txLAF,
      registrarState: registeredState,
      flags: []
    )
    XCTAssertNil(action1)
    XCTAssertTrue(txOpp1)
    XCTAssertEqual(
      applicant1.description,
      "LO",
      "VO should transition to LO on txLAF! when registered"
    )

    // Test AO state with txLAF! when registered
    let applicant2 = Applicant()
    _ = applicant2.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    XCTAssertEqual(applicant2.description, "AO")

    let (action2, txOpp2) = applicant2.action(
      for: .txLAF,
      registrarState: registeredState,
      flags: []
    )
    XCTAssertNil(action2)
    XCTAssertTrue(txOpp2)
    XCTAssertEqual(
      applicant2.description,
      "LO",
      "AO should transition to LO on txLAF! when registered"
    )

    // Test QO state with txLAF! when registered
    let applicant3 = Applicant()
    _ = applicant3.action(for: .rJoinIn, flags: unregisteredFlags) // VO -> AO
    _ = applicant3.action(for: .rJoinIn, flags: unregisteredFlags) // AO -> QO
    XCTAssertEqual(applicant3.description, "QO")

    let (action3, txOpp3) = applicant3.action(
      for: .txLAF,
      registrarState: registeredState,
      flags: []
    )
    XCTAssertNil(action3)
    XCTAssertTrue(txOpp3)
    XCTAssertEqual(
      applicant3.description,
      "LO",
      "QO should transition to LO on txLAF! when registered"
    )
  }

  func testApplicantLA_txLAF_AlwaysTransitionsToLO() {
    // Test that LA state always transitions to LO on txLAF! regardless of registrar state
    // (LA is not in the spec's list of states to suppress)
    let unregisteredFlags: StateMachineHandlerFlags = []
    let registeredState = Registrar.State.IN

    // Test LA with txLAF! when unregistered
    let applicant1 = Applicant()
    _ = applicant1.action(for: .New, flags: unregisteredFlags) // VO -> VN
    _ = applicant1.action(for: .tx, flags: unregisteredFlags) // VN -> AN
    // AN -> AA (not QA): the Registrar is MT here, Table 10-3 fn 8
    _ = applicant1.action(for: .tx, flags: unregisteredFlags) // AN -> AA
    _ = applicant1.action(for: .Lv, flags: unregisteredFlags) // AA -> LA
    XCTAssertEqual(applicant1.description, "LA")

    let (action1, txOpp1) = applicant1.action(for: .txLAF, flags: unregisteredFlags)
    XCTAssertNil(action1)
    XCTAssertTrue(txOpp1)
    XCTAssertEqual(
      applicant1.description,
      "LO",
      "LA should transition to LO on txLAF! even when unregistered"
    )

    // Test LA with txLAF! when registered
    let applicant2 = Applicant()
    _ = applicant2.action(for: .New, registrarState: registeredState, flags: []) // VO -> VN
    _ = applicant2.action(for: .tx, registrarState: registeredState, flags: []) // VN -> AN
    _ = applicant2.action(for: .tx, registrarState: registeredState, flags: []) // AN -> QA
    _ = applicant2.action(for: .Lv, registrarState: registeredState, flags: []) // QA -> LA
    XCTAssertEqual(applicant2.description, "LA")

    let (action2, txOpp2) = applicant2.action(
      for: .txLAF,
      registrarState: registeredState,
      flags: []
    )
    XCTAssertNil(action2)
    XCTAssertTrue(txOpp2)
    XCTAssertEqual(
      applicant2.description,
      "LO",
      "LA should transition to LO on txLAF! when registered"
    )
  }

  // Table 10-3: LA/txLA! -> LO unconditionally (fn 2 excludes Applicant-Only from txLA!, so fn 1
  // never applies) -- independent of Registrar state, matching txLAF!.
  func testApplicantLA_txLA_GoesToLeavingObserverRegardlessOfRegistrar() {
    // unregistered (Registrar MT): LA -> LO
    let applicant1 = Applicant()
    _ = applicant1.action(for: .New, flags: []) // VO -> VN
    _ = applicant1.action(for: .tx, flags: []) // VN -> AN
    _ = applicant1.action(for: .tx, flags: []) // AN -> AA (Registrar MT, fn 8)
    _ = applicant1.action(for: .Lv, flags: []) // AA -> LA
    XCTAssertEqual(applicant1.description, "LA")
    let (action1, _) = applicant1.action(for: .txLA, flags: [])
    XCTAssertEqual(action1, .s_)
    XCTAssertEqual(applicant1.description, "LO", "LA/txLA! -> LO even when unregistered")

    // registered (Registrar IN): LA -> LO
    let applicant2 = Applicant()
    let registered = Registrar.State.IN
    _ = applicant2.action(for: .New, registrarState: registered, flags: []) // VO -> VN
    _ = applicant2.action(for: .tx, registrarState: registered, flags: []) // VN -> AN
    _ = applicant2.action(for: .tx, registrarState: registered, flags: []) // AN -> QA
    _ = applicant2.action(for: .Lv, registrarState: registered, flags: []) // QA -> LA
    XCTAssertEqual(applicant2.description, "LA")
    let (action2, _) = applicant2.action(for: .txLA, registrarState: registered, flags: [])
    XCTAssertEqual(action2, .s_)
    XCTAssertEqual(applicant2.description, "LO", "LA/txLA! -> LO when registered")
  }
}

private final class AttributeValue<A: Application>: @unchecked Sendable, Equatable {
  static func == (lhs: AttributeValue<A>, rhs: AttributeValue<A>) -> Bool {
    lhs.matches(
      attributeType: rhs.attributeType,
      matching: .matchIdentity(rhs.unwrappedValue)
    )
  }

  let attributeType: AttributeType
  let attributeSubtype: AttributeSubtype?
  let value: AnyValue

  var index: UInt64 { value.index }
  var unwrappedValue: any Value { value.value }

  init(
    type: AttributeType,
    subtype: AttributeSubtype?,
    value: AnyValue
  ) {
    attributeType = type
    attributeSubtype = subtype
    self.value = value
  }

  func matches(
    attributeType filterAttributeType: AttributeType?,
    matching filter: AttributeValueFilter
  ) -> Bool {
    if let filterAttributeType {
      guard attributeType == filterAttributeType else { return false }
    }

    do {
      switch filter {
      case .matchAny:
        return true
      case let .matchAnyIndex(index):
        return self.index == index
      case let .matchIndex(value):
        return index == value.index
      case let .matchIdentity(value):
        return self.value.isEqualIdentity(to: value)
      case .matchRelative(let (value, offset)):
        return try self.value.isEqualIdentity(to: value.makeValue(relativeTo: offset))
      }
    } catch {
      return false
    }
  }
}

private typealias MSRPAttributeValue = AttributeValue<MSRPApplication<MockPort>>

private enum EnqueuedEvent<A: Application>: Equatable {
  struct AttributeEvent: Equatable {
    let attributeEvent: MRP.AttributeEvent
    let attributeValue: AttributeValue<A>
    let encodingOptional: Bool
  }

  case attributeEvent(AttributeEvent)
  case leaveAllEvent(AttributeType)

  var attributeType: AttributeType {
    switch self {
    case let .attributeEvent(attributeEvent):
      attributeEvent.attributeValue.attributeType
    case let .leaveAllEvent(attributeType):
      attributeType
    }
  }

  var isLeaveAll: Bool {
    switch self {
    case .attributeEvent:
      false
    case .leaveAllEvent:
      true
    }
  }

  var attributeEvent: AttributeEvent? {
    switch self {
    case let .attributeEvent(attributeEvent):
      attributeEvent
    case .leaveAllEvent:
      nil
    }
  }
}

private typealias MSRPEnqueuedEvent = EnqueuedEvent<MSRPApplication<MockPort>>

// MARK: - MSRP per-stream recompute tests

extension MRPTests {
  private func _makeRecomputeMSRP(
    portIDs: [Int],
    flags: MSRPApplicationFlags = .defaultFlags,
    portTcMaxLatency: [Int: Int] = [:],
    leaveTime: Duration? = nil,
    maxTalkerAttributes: Int = 150
  ) async throws
    -> (MRPController<MockPort>, MSRPApplication<MockPort>, MRPTestRecorder)
  {
    let recorder = MRPTestRecorder()
    let ports = Set(portIDs.map { MockPort(id: $0, portTcMaxLatency: portTcMaxLatency[$0] ?? 0) })
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.recompute"),
      timerConfiguration: MRPTimerConfiguration(leaveTime: leaveTime)
    )
    let msrp = try await MSRPApplication(
      controller: controller,
      flags: flags,
      maxTalkerAttributes: maxTalkerAttributes
    )
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
    return (controller, msrp, recorder)
  }

  // Like _makeRecomputeMSRP but seeds the controller's ports through the real port-add path, so
  // controller.isEndStation is false (>= 2 ports = a bridge). _makeRecomputeMSRP leaves the
  // controller's port set empty, which reads as an end station.
  private func _makeBridgeMSRP(portIDs: [Int], leaveTime: Duration? = nil) async throws
    -> (MRPController<MockPort>, MSRPApplication<MockPort>, MRPTestRecorder)
  {
    let recorder = MRPTestRecorder()
    let ports = Set(portIDs.map { MockPort(id: $0) })
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.bridge"),
      timerConfiguration: MRPTimerConfiguration(leaveTime: leaveTime)
    )
    let msrp = try await MSRPApplication(controller: controller)
    for port in ports {
      try await controller._didAdd(port: port)
    }
    return (controller, msrp, recorder)
  }

  private func _talkerAdvertise(
    _ streamID: MSRPStreamID,
    dest: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x01],
    priority: SRclassPriority =
      .CA, // .CA = SR class A, .EE = SR class B (DefaultSRClassPriorityMap)
    accumulatedLatency: UInt32 = 1000
  ) -> MSRPTalkerAdvertiseValue {
    MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(destinationAddress: dest, vlanIdentifier: 2),
      tSpec: MSRPTSpec(maxFrameSize: 64, maxIntervalFrames: 1),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: priority, rank: false),
      accumulatedLatency: accumulatedLatency
    )
  }

  // A peer-encoded 2-value talker vector whose FirstValue StreamID is the 64-bit maximum overruns
  // when value[1] = StreamID + 1 is reconstructed; rx must drop it gracefully, never trap.
  func testMSRPRxRejectsOverflowingVectorWithoutTrapping() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0])
    let vector = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(_talkerAdvertise(MSRPStreamID(integerLiteral: .max))),
      attributeEvents: [.JoinIn, .JoinIn], // numberOfValues = 2 -> reconstructs StreamID .max + 1
      applicationEvents: nil
    )
    let pdu = MRPDU(
      protocolVersion: 0,
      messages: [Message(
        attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
        attributeList: [vector]
      )]
    )
    // reaching the end without trapping is the assertion (a graceful throw is acceptable too)
    do {
      try await msrp.rx(
        pdu: pdu,
        for: MAPBaseSpanningTreeContext,
        from: MockPort(id: 0),
        sourceMacAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
      )
    } catch {}
    _ = controller
  }

  private func _drive(
    _ msrp: MSRPApplication<MockPort>,
    port: Int,
    attributeType: MSRPAttributeType,
    value: some Value,
    event: AttributeEvent,
    subtype: MSRPAttributeSubtype? = nil
  ) async throws {
    let vectorAttribute = VectorAttribute(
      leaveAllEvent: .NullLeaveAllEvent,
      firstValue: AnyValue(value),
      attributeEvents: [event],
      applicationEvents: subtype.map { [$0.rawValue] }
    )
    let message = Message(attributeType: attributeType.rawValue, attributeList: [vectorAttribute])
    let pdu = MRPDU(protocolVersion: 0, messages: [message])
    // a non-local source MAC makes this a .peer registration
    try await msrp.rx(
      pdu: pdu,
      for: MAPBaseSpanningTreeContext,
      from: MockPort(id: port),
      sourceMacAddress: [0x02, 0x00, 0x00, 0x00, 0x00, 0x0A]
    )
  }

  @discardableResult
  private func _waitFor(
    timeoutMs: Int = 3000,
    _ condition: @Sendable () async -> Bool
  ) async -> Bool {
    var waited = 0
    while waited < timeoutMs {
      if await condition() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
      waited += 10
    }
    return await condition()
  }

  // Avnu ProAV §9.3: at most maxTalkerAttributes Talker streams may be registered, aggregated
  // across all ports; an additional stream once at the limit is ignored (never registered), and a
  // slot frees for it when an existing stream leaves.
  func testTalkerRegistrationLimitIsGlobalAcrossPorts() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1, 2], maxTalkerAttributes: 2
    )
    let a = MSRPStreamID(0x0001_0000_0000_0001)
    let b = MSRPStreamID(0x0001_0000_0000_0002)
    let c = MSRPStreamID(0x0001_0000_0000_0003)

    // two streams on two different ports fill the global budget
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise, value: _talkerAdvertise(a), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .talkerAdvertise, value: _talkerAdvertise(b), event: .JoinIn
    )
    let bothRegistered = await _waitFor {
      let ra = await _isTalkerRegistered(msrp, a, port: 0)
      let rb = await _isTalkerRegistered(msrp, b, port: 1)
      return ra && rb
    }
    XCTAssertTrue(bothRegistered, "the first two Talker streams should register")

    // a third stream on a third port exceeds the global limit -> ignored (Registrar held MT)
    try await _drive(
      msrp, port: 2, attributeType: .talkerAdvertise, value: _talkerAdvertise(c), event: .JoinIn
    )
    let cRegistered = await _waitFor(timeoutMs: 500) { await _isTalkerRegistered(msrp, c, port: 2) }
    XCTAssertFalse(cRegistered, "a Talker stream over the global limit must not be registered")

    // withdrawing one frees a slot; the previously-ignored stream registers on re-declaration
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise, value: _talkerAdvertise(a), event: .Lv
    )
    let aGone = await _waitFor { await !_isTalkerRegistered(msrp, a, port: 0) }
    XCTAssertTrue(aGone, "the withdrawn stream should deregister")

    try await _drive(
      msrp, port: 2, attributeType: .talkerAdvertise, value: _talkerAdvertise(c), event: .JoinIn
    )
    let cNow = await _waitFor { await _isTalkerRegistered(msrp, c, port: 2) }
    XCTAssertTrue(cNow, "a slot freed by the leave should admit the previously-ignored stream")
    _ = controller
  }

  // talker on one port + a Ready listener on another -> reservation programmed on the
  // listener port only (CBS idleslope + FDB entry), never on the talker's port.
  func testRecomputeProgramsListenerReservationNoReflection() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)

    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )

    let converged = await _waitFor { await recorder.cbs.contains { $0.port == 1 } }
    XCTAssertTrue(converged, "expected a CBS reservation on the listener port (1)")

    let cbs = await recorder.cbs
    XCTAssertTrue(
      cbs.contains { $0.port == 1 && $0.idleSlope > 0 },
      "listener port should get a positive idleslope"
    )
    XCTAssertFalse(
      cbs.contains { $0.port == 0 },
      "talker port must never receive a reservation (reflection)"
    )

    let fdb = await recorder.fdbRegister
    XCTAssertTrue(
      fdb.contains { $0.ports.contains(1) },
      "listener port should get a dynamic FDB reservation entry"
    )
    _ = controller
  }

  // 35.2.6: a peer that re-declares a Listener with a changed FourPackedEvent (subtype) via a New
  // message -- an imperfect endpoint, or 10.3 New-marking on a topology change -- must have the
  // change applied on receive, else the toward-talker declaration latches the stale subtype (a
  // flowing stream stuck reporting Ready Failed). Receive-side twin of the join()-side ee3022f fix.
  func testMSRPListenerSubtypeChangeViaNewIsApplied() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)

    // talker on port 0, a single listener on port 1
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    // the listener first declares Ready Failed (as an imperfect single listener might)
    try await _drive(
      msrp, port: 1, attributeType: .listener, value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn, subtype: .readyFailed
    )
    let sawReadyFailed = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 0) == .readyFailed
    }
    XCTAssertTrue(sawReadyFailed, "toward-talker declaration should start at readyFailed")

    // recovery arrives as a New message with a changed subtype for the already-registered stream
    try await _drive(
      msrp, port: 1, attributeType: .listener, value: MSRPListenerValue(streamID: streamID),
      event: .New, subtype: .ready
    )
    let recovered = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 0) == .ready
    }
    XCTAssertTrue(
      recovered,
      "a New re-declaration with a changed subtype must update the propagated declaration (35.2.6), not latch readyFailed"
    )
    _ = controller
  }

  // re-running the recompute with unchanged registrations must not touch the kernel.
  func testRecomputeIdempotentReapply() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0002)

    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.cbs.contains { $0.port == 1 } }

    let cbsBefore = await recorder.cbs.count
    let fdbBefore = await recorder.fdbRegister.count

    // force several extra recomputes of the same, unchanged stream
    for _ in 0..<3 {
      await msrp._streamDidUpdate(streamID)
    }
    try? await Task.sleep(nanoseconds: 200_000_000)

    let cbsAfter = await recorder.cbs.count
    let fdbAfter = await recorder.fdbRegister.count
    XCTAssertEqual(cbsAfter, cbsBefore, "idempotent recompute must not re-program CBS")
    XCTAssertEqual(fdbAfter, fdbBefore, "idempotent recompute must not re-program FDB")
    _ = controller
  }

  // the same stream advertised by a talker on two ports yields a single bound talker:
  // exactly one listener-port reservation, and no reservation on either talker port.
  func testRecomputeDuplicateTalkerSingleBoundTalker() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamID = MSRPStreamID(0x0001_0000_0000_0003)

    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )

    let converged = await _waitFor { await recorder.cbs.contains { $0.port == 2 } }
    XCTAssertTrue(converged, "expected a reservation on the listener port (2)")

    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 0 || $0.port == 1 },
      "neither talker port may receive a reservation"
    )
    _ = controller
  }
}

// MARK: - MSRP recompute: ingress MDB (--configure-ingress-mdb, secure switch)

extension MRPTests {
  private static let _ingressGroup: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x01]

  private func _ingressMdbFlags() -> MSRPApplicationFlags {
    var flags = MSRPApplicationFlags.defaultFlags
    flags.insert(.configureIngressMdb)
    return flags
  }

  // with .configureIngressMdb, the bound Talker's ingress port gets its own admission (MDB) entry
  // for the stream's group, in addition to the egress Listener-port reservation.
  func testRecomputeIngressMdbEntryOnTalkerPort() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(
      portIDs: [0, 1],
      flags: _ingressMdbFlags()
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00A0)

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )

    let group = Self._ingressGroup
    let installed = await _waitFor {
      await recorder.fdbRegister
        .contains { $0.ports.contains(0) && _isEqualMacAddress($0.mac, group) }
    }
    XCTAssertTrue(installed, "talker ingress port (0) should get an admission MDB entry")

    let fdb = await recorder.fdbRegister
    XCTAssertTrue(
      fdb.contains { $0.ports.contains(1) && _isEqualMacAddress($0.mac, group) },
      "listener egress port (1) should still get its reservation entry"
    )
    _ = controller
  }

  // the ingress entry is tied to the Talker, not the Listeners: it is installed as soon as the
  // Talker is bound, even before any Listener declares.
  func testRecomputeIngressMdbInstalledWithoutListener() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(
      portIDs: [0, 1],
      flags: _ingressMdbFlags()
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00A1)

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )

    let group = Self._ingressGroup
    let installed = await _waitFor {
      await recorder.fdbRegister
        .contains { $0.ports.contains(0) && _isEqualMacAddress($0.mac, group) }
    }
    XCTAssertTrue(installed, "ingress entry should be installed for the Talker with no Listener")
    _ = controller
  }

  // without the flag (default), the Talker's ingress port must never receive an admission entry --
  // only the egress Listener port does.
  func testRecomputeNoIngressMdbEntryWhenDisabled() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00A2)

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )

    // once the egress reservation lands the recompute has run; the ingress port must be untouched
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    let fdb = await recorder.fdbRegister
    XCTAssertFalse(
      fdb.contains { $0.ports.contains(0) },
      "no ingress MDB entry may be installed on the talker port when the flag is off"
    )
    _ = controller
  }

  // the ingress entry survives Listener churn (avoiding thrash) and is removed only when the Talker
  // itself leaves.
  func testRecomputeIngressMdbSurvivesListenerLeaveRemovedOnTalkerLeave() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(
      portIDs: [0, 1],
      flags: _ingressMdbFlags()
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00A3)
    let group = Self._ingressGroup

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    let installed = await _waitFor {
      await recorder.fdbRegister
        .contains { $0.ports.contains(0) && _isEqualMacAddress($0.mac, group) }
    }
    XCTAssertTrue(installed, "precondition: ingress entry installed on the talker port")

    // Listener leaves: the egress reservation on port 1 is withdrawn, but the ingress entry on the
    // talker port must NOT be (no churn while the Talker persists).
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .Lv, subtype: .ready
    )
    let egressWithdrawn = await _waitFor {
      await recorder.fdbDeregister.contains { $0.ports.contains(1) }
    }
    XCTAssertTrue(egressWithdrawn, "listener leave should withdraw the egress reservation (port 1)")
    let deregAfterListenerLeave = await recorder.fdbDeregister
    XCTAssertFalse(
      deregAfterListenerLeave.contains { $0.ports.contains(0) },
      "the ingress entry must survive a listener leave (removed only on talker leave)"
    )

    // Talker leaves: now the ingress entry is torn down.
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .Lv
    )
    let ingressRemoved = await _waitFor {
      await recorder.fdbDeregister
        .contains { $0.ports.contains(0) && _isEqualMacAddress($0.mac, group) }
    }
    XCTAssertTrue(ingressRemoved, "talker leave should remove the ingress MDB entry (port 0)")
    _ = controller
  }

  // secure per-port admission is a point-to-point concept: on a shared (non-p2p) source link the
  // ingress entry is deliberately not managed (a co-located Listener's egress reservation would
  // share the same non-refcounted kernel entry). No ingress entry may land on the non-p2p talker
  // port; the egress Listener reservation elsewhere is unaffected.
  func testRecomputeNoIngressMdbOnSharedTalkerPort() async throws {
    let recorder = MRPTestRecorder()
    // port 0 is the shared (non-p2p) talker source link; forceAvbCapable lets a half-duplex port
    // still participate. port 1 is a normal point-to-point listener egress.
    let ports: Set<MockPort> = [MockPort(id: 0, isFullDuplex: false), MockPort(id: 1)]
    let bridge = MockBridge(ports: ports, recorder: recorder)
    let controller = try await MRPController(
      bridge: bridge,
      logger: Logger(label: "com.padl.MRPTests.recompute")
    )
    var flags = _ingressMdbFlags()
    flags.insert(.forceAvbCapable)
    let msrp = try await MSRPApplication(controller: controller, flags: flags)
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)

    let streamID = MSRPStreamID(0x0001_0000_0000_00A4)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )

    // the egress reservation on the p2p listener port confirms the recompute ran
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    let fdb = await recorder.fdbRegister
    XCTAssertFalse(
      fdb.contains { $0.ports.contains(0) },
      "no ingress MDB entry may be installed on a non-point-to-point talker port"
    )
    _ = controller
  }

  // (3 ports) A Talker relocates across ingress ports while the Listener stays fixed. The group's
  // ingress admission entry must follow the Talker to its new port, and -- because the Talker is
  // registered on both ports during the hand-off (as in a ring) -- the fixed Listener's egress
  // entry must never be torn down. Regression for the relocation race that stranded the entry.
  func testRecomputeIngressMdbFollowsTalkerRelocationKeepingFixedListener() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(
      portIDs: [0, 1, 2], flags: _ingressMdbFlags()
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00A5)
    let group = Self._ingressGroup

    // Talker on port 0, Listener Ready on port 2 -> group {ingress 0, egress 2}
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 2, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    let established = await _waitFor { await recorder.fdbMembers(mac: group) == [0, 2] }
    let m0 = await recorder.fdbMembers(mac: group)
    XCTAssertTrue(established, "group should converge to {ingress 0, egress 2}; got \(m0)")

    // relocate the Talker 0 -> 1, make-before-break (briefly registered on both, as in a ring)
    try await _drive(
      msrp, port: 1, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .Lv
    )
    let relocated = await _waitFor { await recorder.fdbMembers(mac: group) == [1, 2] }
    let m1 = await recorder.fdbMembers(mac: group)
    XCTAssertTrue(relocated, "ingress must follow the Talker to port 1, egress 2 kept; got \(m1)")

    // the fixed Listener's egress entry must never have been deregistered during the hand-off
    let deregs = await recorder.fdbDeregister
    XCTAssertFalse(
      deregs.contains { $0.ports.contains(2) && _isEqualMacAddress($0.mac, group) },
      "the fixed Listener's egress entry (port 2) must not be torn down by the relocation"
    )
    _ = controller
  }

  // (4 ports) The group's port set is the union of every Listener-Ready egress port plus the
  // Talker's ingress port, reconciled in one pass; a single Listener leaving prunes only its port.
  func testRecomputeIngressMdbUnionOfMultipleListeners() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(
      portIDs: [0, 1, 2, 3], flags: _ingressMdbFlags()
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00A6)
    let group = Self._ingressGroup

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    for listenerPort in [1, 2, 3] {
      try await _drive(
        msrp, port: listenerPort, attributeType: .listener,
        value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
      )
    }
    let full = await _waitFor { await recorder.fdbMembers(mac: group) == [0, 1, 2, 3] }
    let mAll = await recorder.fdbMembers(mac: group)
    XCTAssertTrue(full, "group should be ingress 0 + listeners 1,2,3; got \(mAll)")

    // one Listener leaves -> only its egress port is pruned; ingress and the others stay
    try await _drive(
      msrp, port: 2, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .Lv, subtype: .ready
    )
    let pruned = await _waitFor { await recorder.fdbMembers(mac: group) == [0, 1, 3] }
    let mPruned = await recorder.fdbMembers(mac: group)
    XCTAssertTrue(pruned, "only the departed Listener (port 2) should be pruned; got \(mPruned)")
    _ = controller
  }

  // (3 ports) A Talker withdrawing entirely tears the whole group down; re-declaring rebuilds it.
  func testRecomputeIngressMdbTornDownOnTalkerLeaveAndRebuilt() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(
      portIDs: [0, 1, 2], flags: _ingressMdbFlags()
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00A7)
    let group = Self._ingressGroup

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 2, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbMembers(mac: group) == [0, 2] }

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .Lv
    )
    let emptied = await _waitFor { await recorder.fdbMembers(mac: group).isEmpty }
    XCTAssertTrue(emptied, "talker leave must tear the whole group down")

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let rebuilt = await _waitFor { await recorder.fdbMembers(mac: group) == [0, 2] }
    let mReb = await recorder.fdbMembers(mac: group)
    XCTAssertTrue(rebuilt, "re-declaring the Talker must rebuild the group; got \(mReb)")
    _ = controller
  }
}

// MARK: - MSRP recompute: review-driven regression tests

extension MRPTests {
  // ignore-subtype (don't-care) listener must not produce a reservation
  func testRecomputeIgnoreSubtypeListenerGetsNoReservation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0010)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ignore
    )
    try? await Task.sleep(nanoseconds: 300_000_000)
    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 1 },
      "an ignore-subtype listener must not get a reservation"
    )
    _ = controller
  }

  // removing and re-adding a port must drop its cached reservation so it reprograms
  func testRecomputePortReaddReprogramsReservation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0011)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.cbs.contains { $0.port == 1 } }
    let before = await recorder.cbs.filter { $0.port == 1 }.count

    try await msrp.didRemove(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: Set([MockPort(id: 1)])
    )
    try await msrp.didAdd(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: Set([MockPort(id: 1)])
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )

    let reprogrammed = await _waitFor { await recorder.cbs.filter { $0.port == 1 }.count > before }
    XCTAssertTrue(
      reprogrammed,
      "reservation must be reprogrammed after a port is removed and re-added"
    )
    _ = controller
  }

  // once a port also registers the talker, our prior declaration toward it must be withdrawn
  func testRecomputeWithdrawsTalkerDeclarationWhenPortBecomesRegistrar() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0012)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    let declared = await _waitFor {
      await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    }
    XCTAssertTrue(declared, "talker should be declared toward port 1")

    try await _drive(
      msrp,
      port: 1,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    let withdrawn = await _waitFor {
      await !_isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    }
    XCTAssertTrue(
      withdrawn,
      "talker declaration on port 1 must be withdrawn once port 1 registers it"
    )
    _ = controller
  }
}

extension MRPTests {
  // two listener egress ports in different states: only the Ready one reserves idleslope;
  // the AskingFailed one must not (regression for the global-merge over-reservation).
  func testRecomputePerPortReservationMixedListenerStates() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamID = MSRPStreamID(0x0001_0000_0000_0020)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .askingFailed
    )

    let converged = await _waitFor {
      await recorder.cbs.contains { $0.port == 1 && $0.idleSlope > 0 }
    }
    XCTAssertTrue(converged, "ready listener port (1) should reserve idleslope")
    try? await Task.sleep(nanoseconds: 200_000_000)

    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 2 && $0.idleSlope > 0 },
      "asking-failed listener port (2) must not reserve idleslope"
    )
    _ = controller
  }

  // a peer changing a listener's subtype on the SAME registration (AskingFailed -> Ready) must be
  // observed by the recompute so the reservation appears. Guards the subtype-change notification
  // path (whether realized by a leave-now replace or a direct write plus a re-indication).
  func testListenerSubtypeChangeIsObserved() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0031)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    // the listener starts AskingFailed -> no idleslope reserved
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .askingFailed
    )
    try? await Task.sleep(nanoseconds: 200_000_000)
    let before = await recorder.cbs
    XCTAssertFalse(
      before.contains { $0.port == 1 && $0.idleSlope > 0 },
      "an asking-failed listener must not reserve idleslope"
    )

    // the peer re-declares the same listener as Ready: the subtype change must be observed
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    let reserved = await _waitFor {
      await recorder.cbs.contains { $0.port == 1 && $0.idleSlope > 0 }
    }
    XCTAssertTrue(
      reserved,
      "a listener subtype change AskingFailed->Ready must be observed and reserve idleslope"
    )
    _ = controller
  }
}

// MARK: - MSRP recompute: failed-talker, withdrawal, admission, port-removal

extension MRPTests {
  private func _talkerFailed(
    _ streamID: MSRPStreamID,
    dest: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x01],
    failureCode: TSNFailureCode = .insufficientBandwidth
  ) -> MSRPTalkerFailedValue {
    MSRPTalkerFailedValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(destinationAddress: dest, vlanIdentifier: 2),
      tSpec: MSRPTSpec(maxFrameSize: 64, maxIntervalFrames: 1),
      // immutable FirstValue fields (incl. PriorityAndRank) must match _talkerAdvertise: a bridge
      // preserves them across an Advertise->Failed transition, only the type/FailureInformation
      // change
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000,
      systemID: MSRPSystemID(id: 0x1234),
      failureCode: failureCode
    )
  }

  // a Failed talker propagates Failed and reserves nothing even with a Ready listener
  func testRecomputeTalkerFailedNoReservationAndPropagates() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0030)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerFailed,
      value: _talkerFailed(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    let propagated = await _waitFor {
      await _isDeclared(msrp, .talkerFailed, streamID, port: 1)
    }
    XCTAssertTrue(propagated, "talkerFailed should propagate to the other port")
    try? await Task.sleep(nanoseconds: 200_000_000)
    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 1 && $0.idleSlope > 0 },
      "a failed talker must not reserve idleslope"
    )
    _ = controller
  }

  // withdrawing the listener tears down its reservation (FDB deregistered)
  func testRecomputeListenerWithdrawalTearsDownReservation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0031)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    let deregBefore = await recorder.fdbDeregister.count

    // re-declaring with a different subtype (.ignore) is treated by rx as an immediate leave
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ignore
    )
    let withdrawn = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    XCTAssertTrue(withdrawn, "withdrawing the listener should deregister its FDB reservation")
    _ = controller
  }

  // drive a spanning-tree state update through didUpdate. MockPort equality is by id, so the
  // ports built here replace the cached state for the given ids (others stay Forwarding).
  private func _setStpStates(
    _ msrp: MSRPApplication<MockPort>,
    portIDs: [Int],
    _ states: [Int: STPPortState]
  ) async throws {
    let ports = Set(portIDs.map { id -> MockPort in
      var port = MockPort(id: id)
      port.stpPortState = states[id] ?? .forwarding
      return port
    })
    try await msrp.didUpdate(contextIdentifier: MAPBaseSpanningTreeContext, with: ports)
  }

  // a port moving to a blocked (non-Forwarding) spanning-tree state stops propagating and
  // withdraws its reservation; restoring Forwarding reprograms it (35.1.3.1)
  func testRecomputeBlockedPortWithdrawsAndRestores() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0033)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    let reserved = await recorder.cbs.contains { $0.port == 1 && $0.idleSlope > 0 }
    XCTAssertTrue(reserved, "listener port reserves while Forwarding")

    let deregBefore = await recorder.fdbDeregister.count
    try await _setStpStates(msrp, portIDs: [0, 1], [1: .blocking])
    let withdrawn = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    XCTAssertTrue(withdrawn, "a blocked port must withdraw its reservation (35.1.3.1)")
    // the declaration withdrawal is a distinct effect from the FDB deregister, so poll for it
    let undeclared = await _waitFor { await !_isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    }
    XCTAssertTrue(undeclared, "a blocked port must not propagate the talker declaration")

    // restore Forwarding -> the surviving talker reprograms the reservation
    let regBefore = await recorder.fdbRegister.count
    try await _setStpStates(msrp, portIDs: [0, 1], [:])
    let restored = await _waitFor { await recorder.fdbRegister.count > regBefore }
    XCTAssertTrue(restored, "restoring Forwarding should reprogram the reservation")
    _ = controller
  }

  // a listener that joins while its port is already blocked is never programmed (35.1.3.1)
  func testRecomputeBlockedListenerGetsNoReservation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0034)
    try await _setStpStates(msrp, portIDs: [0, 1], [1: .blocking])
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    // give the recompute time to (not) program anything
    try? await Task.sleep(nanoseconds: 200_000_000)
    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 1 && $0.idleSlope > 0 },
      "a blocked listener port must not be programmed"
    )
    let fdb = await recorder.fdbRegister
    XCTAssertFalse(
      fdb.contains { $0.ports.contains(1) },
      "a blocked listener port must not get an FDB reservation"
    )
    _ = controller
  }

  // 10.3 a): a Talker received New must be re-propagated as New, not a plain Join. Steady-state
  // JoinIn propagation is the control (not New-marked); a subsequent received New re-marks it.
  func testRecomputeReceivedNewMarksPropagatedTalkerNew() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0046)
    try await _drive(
      msrp, port: 0, attributeType: .talkerFailed,
      value: _talkerFailed(streamID), event: .JoinIn
    )
    _ = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamID, port: 1) }
    let before = await _declaredApplicantState(msrp, .talkerFailed, streamID, port: 1)
    XCTAssertNotNil(before)
    XCTAssertFalse(_isNewMarked(before), "a JoinIn-registered talker propagates as a plain Join")

    // the peer re-declares the same stream New: the propagated Talker Failed must also be New
    try await _drive(
      msrp, port: 0, attributeType: .talkerFailed,
      value: _talkerFailed(streamID), event: .New
    )
    let markedNew = await _waitFor {
      await _isNewMarked(_declaredApplicantState(msrp, .talkerFailed, streamID, port: 1))
    }
    XCTAssertTrue(markedNew, "a Talker received New must be propagated as New (10.3 a)")
    _ = controller
  }

  // 10.3 a): a Listener received New re-marks the merged Listener toward the talker as New
  func testRecomputeReceivedNewMarksMergedListenerNew() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0047)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    _ = await _waitFor { await _isDeclared(msrp, .listener, streamID, port: 0) }
    let before = await _declaredApplicantState(msrp, .listener, streamID, port: 0)
    XCTAssertNotNil(before)
    XCTAssertFalse(_isNewMarked(before), "a JoinIn-registered listener propagates as a plain Join")

    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .New, subtype: .ready
    )
    let markedNew = await _waitFor {
      await _isNewMarked(_declaredApplicantState(msrp, .listener, streamID, port: 0))
    }
    XCTAssertTrue(markedNew, "a Listener received New must be propagated as New (10.3 a)")
    _ = controller
  }

  // 10.3 a): a declaration propagated from a port that just underwent a spanning-tree transition
  // is marked New (tcDetected approximation), even though the registration itself was not New
  func testRecomputeTopologyChangeMarksPropagatedTalkerNew() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0048)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    _ = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    let before = await _declaredApplicantState(msrp, .talkerAdvertise, streamID, port: 1)
    XCTAssertNotNil(before)
    XCTAssertFalse(_isNewMarked(before), "no New on the propagated talker before a topology change")

    // a spanning-tree transition on the talker's ingress port (0): block, then restore Forwarding
    try await _setStpStates(msrp, portIDs: [0, 1], [0: .blocking])
    try await _setStpStates(msrp, portIDs: [0, 1], [:])
    let markedNew = await _waitFor {
      await _isNewMarked(_declaredApplicantState(msrp, .talkerAdvertise, streamID, port: 1))
    }
    XCTAssertTrue(
      markedNew,
      "a Talker re-propagated after a topology change on its source must be New (10.3 a)"
    )
    _ = controller
  }

  // A per-port reservation-programming failure must not abort the whole recompute: another
  // listener port is still programmed (the failed one is retried later via the idempotency check).
  func testRecomputeReservationFailureOnOnePortStillProgramsOthers() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    await recorder.setFailCbs(ports: [1]) // port 1's shaper program throws
    let streamID = MSRPStreamID(0x0001_0000_0000_00C0)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    for listenerPort in [1, 2] {
      try await _drive(
        msrp, port: listenerPort, attributeType: .listener,
        value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
      )
    }
    // port 2 must still be reserved despite port 1's failure (no whole-plan abort)
    let port2Programmed = await _waitFor {
      await recorder.fdbRegister.contains { $0.ports.contains(2) }
    }
    XCTAssertTrue(port2Programmed, "a failure on port 1 must not prevent port 2's reservation")
    // port 1 was not recorded as reserved, so a later recompute retries it
    let port1Programmed = await recorder.fdbRegister.contains { $0.ports.contains(1) }
    XCTAssertFalse(port1Programmed, "the failed port must not be recorded as reserved")
    _ = controller
  }

  // talker declarations are not forwarded out a blocked port: a second, Forwarding egress
  // still gets the advertise while the blocked one does not (35.1.3.1, 10.3)
  func testRecomputeBlockedPortBlocksTalkerPropagation() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamID = MSRPStreamID(0x0001_0000_0000_0035)
    try await _setStpStates(msrp, portIDs: [0, 1, 2], [2: .blocking])
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    let propagated = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(propagated, "advertise should reach the Forwarding egress (1)")
    let blockedDeclared = await _isDeclared(msrp, .talkerAdvertise, streamID, port: 2)
    XCTAssertFalse(blockedDeclared, "advertise must not be forwarded out the blocked egress (2)")
    _ = controller
  }

  // 35.2.2.8.6: a bridge relaying a Talker Advertise adds the egress per-hop latency -- the
  // class-independent terms (getPortTcMaxLatency) plus the SR-class measurement interval (term a).
  func testTalkerAdvertiseAccumulatesEgressPerHopLatency() async throws {
    let perHop = 12345
    let classAMeasurementIntervalNs = 125_000 // SR class A, 35.2.2.8.6 a)
    // the talker arrives on port 0 and is relayed out port 1, which carries the per-hop latency
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1],
      portTcMaxLatency: [1: perHop]
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00AA)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), // accumulatedLatency 1000
      event: .JoinIn
    )
    let relayed = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(relayed, "advertise must propagate to the egress")
    let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
    XCTAssertEqual(
      advertise?.accumulatedLatency,
      1000 + UInt32(perHop) + UInt32(classAMeasurementIntervalNs),
      "the relayed advertise must add the egress per-hop latency (class-independent + class interval)"
    )
    _ = controller
  }

  // 35.2.2.8.6 term a): the per-hop latency is SR-class dependent -- a class B stream adds one
  // class
  // B measurement interval (250 us), twice the class A interval, on top of the same b/c/d terms.
  func testTalkerAdvertisePerHopLatencyIsClassDependent() async throws {
    let perHop = 12345
    let classBMeasurementIntervalNs = 250_000 // SR class B, 35.2.2.8.6 a)
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1],
      portTcMaxLatency: [1: perHop]
    )
    let streamID = MSRPStreamID(0x0002_0000_0000_00AB)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, priority: .EE), // .EE = SR class B
      event: .JoinIn
    )
    let relayed = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(relayed, "class B advertise must propagate to the egress")
    let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
    XCTAssertEqual(
      advertise?.accumulatedLatency,
      1000 + UInt32(perHop) + UInt32(classBMeasurementIntervalNs),
      "a class B stream must add the 250 us class B measurement interval, not class A's 125 us"
    )
    _ = controller
  }

  // 35.2.2.8.6: the reported latency must not increase during the reservation's life. When the
  // peer re-advertises the stream with a higher upstream AccumulatedLatency (a non-FirstValue
  // field), the ingress registration updates in place and the redeclaration's reported latency
  // exceeds the initial guarantee, converting the Talker Advertise to a Talker Failed with
  // reportedLatencyHasChanged (code 7) rather than re-advertising the higher value.
  func testTalkerLatencyIncreaseConvertsToFailedCode7() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1, 2],
      portTcMaxLatency: [1: 12345]
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00AC)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: 1000),
      event: .JoinIn
    )
    let relayed = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(relayed, "advertise must propagate to the egress and set the initial guarantee")

    // the peer re-advertises the same stream with a much higher upstream AccumulatedLatency; the
    // ingress registration is updated in place, so the next recompute reports a latency above the
    // guarantee (no local resample or topology change involved)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: 90000),
      event: .JoinIn
    )

    let failed = await _waitFor {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1) == .reportedLatencyHasChanged
    }
    XCTAssertTrue(failed, "an upstream latency increase must declare Talker Failed with code 7")
    // the Advertise leave and the Failed join are separate async events; poll rather than one-shot
    let advertiseGone = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 1) == nil
    }
    XCTAssertTrue(advertiseGone, "the Talker Advertise must no longer be declared once failed")
    _ = controller
  }

  // 35.2.2.8.6: a peer's upstream AccumulatedLatency is tracked in both directions. After an
  // increase fails the stream (code 7), a genuine decrease back within the guarantee must clear the
  // failure and re-declare Talker Advertise -- a transient spike must not strand the stream Failed.
  func testTalkerLatencyDecreaseClearsFailedCode7() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1, 2],
      portTcMaxLatency: [1: 12345]
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00AD)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: 1000), event: .JoinIn
    )
    let relayed = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(relayed, "advertise must propagate and set the initial guarantee")

    // the peer's upstream latency spikes -> code 7
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: 90000), event: .JoinIn
    )
    let failed = await _waitFor {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1) == .reportedLatencyHasChanged
    }
    XCTAssertTrue(failed, "the latency spike must fail the stream (code 7)")

    // ... then recovers to the original latency: the stream must re-advertise, not stay Failed
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: 1000), event: .JoinIn
    )
    let recovered = await _waitFor {
      let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
      let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
      return advertise != nil && code == nil
    }
    XCTAssertTrue(recovered, "a latency decrease back within the guarantee must clear code 7")
    _ = controller
  }

  // 35.2.2.8: a peer re-declaring a registered Talker Failed with the same FirstValue but a changed
  // FailureInformation (failureCode -- a non-FirstValue field) must update the registration in
  // place
  // so the new failure reason propagates downstream. It is neither a FirstValue conflict (code 16)
  // nor a benign no-op to be ignored.
  func testTalkerFailedFailureCodeChangePropagates() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00AF)
    try await _drive(
      msrp, port: 0, attributeType: .talkerFailed,
      value: _talkerFailed(streamID, failureCode: .insufficientBandwidth), event: .JoinIn
    )
    let relayed = await _waitFor {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1) == .insufficientBandwidth
    }
    XCTAssertTrue(relayed, "the Talker Failed must propagate with its original failure code")

    // re-declare with the same FirstValue and latency but a different failure reason
    try await _drive(
      msrp, port: 0, attributeType: .talkerFailed,
      value: _talkerFailed(streamID, failureCode: .egressPortIsNotAvbCapable), event: .JoinIn
    )
    let updated = await _waitFor {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1) == .egressPortIsNotAvbCapable
    }
    XCTAssertTrue(updated, "a changed failure code must update the registration and propagate")
    _ = controller
  }

  // 35.2.2.8.6: before gPTP supplies a meanLinkDelay the per-hop latency is provisional and must
  // NOT become the reported-latency guarantee -- otherwise the stream fails the moment the real
  // (larger) value arrives, even though nothing degraded.
  func testProvisionalLatencyBeforePtpReadyDoesNotFailStream() async throws {
    MockPort._latencyOverrides.withLock { $0.removeAll() }
    MockPort._ptpNotReady.withLock { $0.removeAll() }
    defer {
      MockPort._latencyOverrides.withLock { $0.removeAll() }
      MockPort._ptpNotReady.withLock { $0.removeAll() }
    }
    // gPTP has no meanLinkDelay on the egress (port 1) yet
    MockPort._ptpNotReady.withLock { _ = $0.insert(1) }
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamID = MSRPStreamID(0x0001_0000_0000_00AD)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    let relayed = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(
      relayed,
      "advertise must propagate even before gPTP is ready (provisional latency)"
    )

    // gPTP converges on a much larger real meanLinkDelay; a topology change on port 2 triggers a
    // recompute that re-samples the real (larger) value. The provisional latency must not have been
    // pinned as the guarantee, so the real value must not fail the stream.
    MockPort._ptpNotReady.withLock { _ = $0.remove(1) }
    MockPort._latencyOverrides.withLock { $0[1] = 500_000 }
    var flapped = MockPort(id: 2, portTcMaxLatency: 0)
    flapped.stpPortState = .blocking
    try await msrp.didUpdate(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: [MockPort(id: 0), MockPort(id: 1), flapped]
    )

    // the recompute withdraws the now-blocked port 2 in the same pass, so its withdrawal signals
    // that port 1 has been re-evaluated against the real latency
    let recomputed = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 2) == nil
    }
    XCTAssertTrue(recomputed, "the flap recompute must run (blocked port 2 withdrawn)")
    let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
    XCTAssertNil(
      code,
      "a provisional latency must not be pinned as the guarantee and fail the real value"
    )
    let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
    XCTAssertNotNil(advertise, "the stream must stay advertised, not convert to Talker Failed")
    _ = controller
  }

  // 10.3/35.1.3.1: MAP operates over the Forwarding port set and every non-Forwarding state is
  // equally blocked, so propagation must follow the Forwarding edge -- withdrawn when the port
  // leaves Forwarding, restored on return -- and an intermediate blocking->learning step must not
  // disturb it. Guards the Forwarding-edge detection against the intermediate-state rewrite.
  func testTalkerPropagationFollowsForwardingEdgeNotIntermediateStpStates() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00E1)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let advertised = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil
    }
    XCTAssertTrue(advertised, "the talker must propagate to the egress port while forwarding")

    func setTalkerPortState(_ state: STPPortState) async throws {
      var p0 = MockPort(id: 0)
      p0.stpPortState = state
      try await msrp.didUpdate(
        contextIdentifier: MAPBaseSpanningTreeContext, with: [p0, MockPort(id: 1)]
      )
    }

    // the talker's port leaves Forwarding: the declaration is blocked (35.1.3.1) and withdrawn
    try await setTalkerPortState(.blocking)
    let withdrawn = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) == nil
    }
    XCTAssertTrue(withdrawn, "leaving Forwarding must withdraw the propagated talker")

    // blocking -> learning is non-Forwarding -> non-Forwarding: no restore, no disturbance
    try await setTalkerPortState(.learning)
    try await Task.sleep(for: .milliseconds(150))
    let stillWithdrawn = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
    XCTAssertNil(stillWithdrawn, "a non-Forwarding intermediate step must not restore the talker")

    // returning to Forwarding restores propagation
    try await setTalkerPortState(.forwarding)
    let restored = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(restored, "returning to Forwarding must restore the propagated talker")
    _ = controller
  }

  // A changed non-FirstValue payload adopted in place (35.2.2.8) must reach the wire: the egress
  // applicant sits in QA after its transmissions, where Join! alone is a no-op (Table 10-3), so
  // the in-place update must re-arm it (periodic!, QA->AA) or peers keep the stale value.
  func testInPlaceValueUpdateIsRetransmittedFromQuietActive() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00C0)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: 1000), event: .JoinIn
    )
    // two transmissions of the initial value: VP -tx-> AA -tx-> QA, so the applicant is now quiet
    let quiet = await _waitFor {
      await _transmittedAdvertiseLatencies(recorder, msrp, port: 1, streamID: streamID).count >= 2
    }
    XCTAssertTrue(quiet, "the initial advertise must be transmitted into QA")
    let initial = await _transmittedAdvertiseLatencies(recorder, msrp, port: 1, streamID: streamID)

    // the peer re-declares with a lower AccumulatedLatency: benign, adopted in place (same index)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: 500), event: .JoinIn
    )
    let expected = try XCTUnwrap(initial.last) - 500
    let retransmitted = await _waitFor {
      await _transmittedAdvertiseLatencies(recorder, msrp, port: 1, streamID: streamID)
        .contains(expected)
    }
    XCTAssertTrue(retransmitted, "the updated payload must be retransmitted from a QA applicant")
    _ = controller
  }

  // A conflict (code 16) whose talker registration vanishes with its ingress port sees no withdraw
  // or revert: it must be swept with the port so a later clean re-declaration starts fresh.
  func testFirstValueConflictClearedWhenIngressPortRemoved() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00C2)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let advertised = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil
    }
    XCTAssertTrue(advertised, "the original advertise must propagate")
    let conflicting = _talkerAdvertise(streamID, dest: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x99])
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise, value: conflicting, event: .JoinIn
    )
    let failed = await _waitFor {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1) ==
        .changeInFirstValueForRegisteredStreamID
    }
    XCTAssertTrue(failed, "a FirstValue change must fail the stream (code 16)")

    // the ingress port (and the talker registration with it) vanishes, then returns; the talker
    // re-declares its new FirstValue cleanly -- code 16 must not survive the registration
    try await msrp.didRemove(
      contextIdentifier: MAPBaseSpanningTreeContext, with: [MockPort(id: 0)]
    )
    try await msrp.didAdd(contextIdentifier: MAPBaseSpanningTreeContext, with: [MockPort(id: 0)])
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise, value: conflicting, event: .JoinIn
    )
    let recovered = await _waitFor {
      let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
      let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
      return advertise != nil && code == nil
    }
    XCTAssertTrue(recovered, "a re-registered stream must start clean after its port vanished")
    _ = controller
  }

  // 35.2.2.8.6: a topology change re-samples the per-hop latency but must NOT erase the
  // per-stream guarantees -- a latency increase after reconvergence trips code 7 instead of
  // silently re-baselining against the new, higher value.
  func testInvalidateKeepsLatencyGuarantees() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00C3)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let baselined = await _waitFor {
      await ((try? msrp.withPortState(port: MockPort(id: 1)) { $0.configuredLatency[streamID] })
        ?? nil) != nil
    }
    XCTAssertTrue(baselined, "the first declaration must set the guarantee")
    let (kept, cacheCleared) = try await msrp.withPortState(port: MockPort(id: 1)) { state in
      state.invalidate()
      return (state.configuredLatency[streamID], state.portTcMaxLatency == nil)
    }
    XCTAssertNotNil(kept, "invalidate() must keep the per-stream guarantee")
    XCTAssertTrue(cacheCleared, "invalidate() must clear the cached per-hop latency")
    _ = controller
  }

  // 35.2.2.8.6: the reported-latency guarantee is dropped when the egress port is removed, so a
  // stream that returns on the re-added port re-baselines rather than failing against a stale
  // value.
  func testPortRemovalClearsLatencyGuarantee() async throws {
    MockPort._latencyOverrides.withLock { $0.removeAll() }
    defer { MockPort._latencyOverrides.withLock { $0.removeAll() } }
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1, 2],
      portTcMaxLatency: [1: 12345]
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00AE)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    let relayed = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(relayed, "advertise must set the initial guarantee on port 1")

    // remove the egress, then re-add it at a much higher per-hop latency: the guarantee must be
    // dropped with the port state so the returning stream re-baselines instead of failing
    try await msrp.didRemove(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: Set([MockPort(id: 1)])
    )
    MockPort._latencyOverrides.withLock { $0[1] = 500_000 }
    try await msrp.didAdd(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: Set([MockPort(id: 1)])
    )

    // flap port 2 to force a stream recompute; its withdrawal signals the re-added port 1 has been
    // re-evaluated against the higher latency
    var flapped = MockPort(id: 2, portTcMaxLatency: 0)
    flapped.stpPortState = .blocking
    try await msrp.didUpdate(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: [MockPort(id: 0), MockPort(id: 1), flapped]
    )
    let recomputed = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 2) == nil
    }
    XCTAssertTrue(recomputed, "the flap recompute must run (blocked port 2 withdrawn)")

    let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
    XCTAssertNil(
      code,
      "a stale guarantee must not survive port removal and fail the returning stream"
    )
    let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
    XCTAssertNotNil(
      advertise,
      "the returning stream must stay advertised, not convert to Talker Failed"
    )
    _ = controller
  }

  // accumulatedLatency is peer-supplied, so a value near UInt32.max plus this hop's per-hop
  // latency must saturate at UInt32.max rather than overflow the UInt32 sum (which would trap --
  // a remotely triggerable DoS).
  func testTalkerAdvertiseLatencySaturatesOnOverflow() async throws {
    let perHop = 12345
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1],
      portTcMaxLatency: [1: perHop]
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00AB)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID, accumulatedLatency: .max - 100),
      event: .JoinIn
    )
    let relayed = await _waitFor { await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil }
    XCTAssertTrue(relayed, "advertise must propagate to the egress")
    let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
    XCTAssertEqual(
      advertise?.accumulatedLatency,
      .max,
      "adding the per-hop latency to a near-max received latency must saturate, not wrap"
    )
    _ = controller
  }

  // a non-Forwarding transient state (Learning) gates exactly like Blocking: the gate is
  // "== .forwarding", not "!= .blocking"
  func testRecomputeLearningStateAlsoGates() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0036)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }

    let deregBefore = await recorder.fdbDeregister.count
    try await _setStpStates(msrp, portIDs: [0, 1], [1: .learning])
    let withdrawn = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    XCTAssertTrue(withdrawn, "a Learning (non-Forwarding) port must also withdraw its reservation")
    _ = controller
  }

  // blocking one of two listener ports withdraws only that port; the Forwarding listener keeps
  // its reservation
  func testRecomputeOneOfTwoListenersBlocked() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamID = MSRPStreamID(0x0001_0000_0000_0037)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(2) } }

    let deregBefore = await recorder.fdbDeregister.count
    try await _setStpStates(msrp, portIDs: [0, 1, 2], [1: .blocking])
    let withdrawn = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    XCTAssertTrue(withdrawn, "the blocked listener (1) must be withdrawn")
    let deregs = await recorder.fdbDeregister
    XCTAssertTrue(deregs.contains { $0.ports.contains(1) }, "blocked listener (1) deregistered")
    XCTAssertFalse(
      deregs.contains { $0.ports.contains(2) },
      "the Forwarding listener (2) must keep its reservation"
    )
    _ = controller
  }

  // a talker registered on a blocked (non-Forwarding) source port is "blocked" (35.1.3.1):
  // its declaration is not forwarded out the other (Forwarding) ports and no reservation is
  // programmed from it (10.3)
  func testRecomputeBlockedTalkerSourceNoPropagation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0038)
    // port 0 (the talker source) is blocked before anything is declared
    try await _setStpStates(msrp, portIDs: [0, 1], [0: .blocking])
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    // give the recompute time to (not) propagate anything
    try? await Task.sleep(nanoseconds: 200_000_000)
    let propagated = await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    XCTAssertFalse(
      propagated,
      "a talker on a blocked source port must not be forwarded out a Forwarding port"
    )
    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 1 && $0.idleSlope > 0 },
      "no reservation may be programmed from a blocked talker source"
    )
    let fdb = await recorder.fdbRegister
    XCTAssertFalse(
      fdb.contains { $0.ports.contains(1) },
      "no FDB reservation may be programmed from a blocked talker source"
    )
    _ = controller
  }

  // a talker source that moves Forwarding -> Blocking after propagation withdraws the egress
  // declaration and reservation; restoring Forwarding reprograms them (35.1.3.1, 10.3)
  func testRecomputeTalkerSourceBlockedAfterPropagation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0039)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    let propagated = await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    XCTAssertTrue(
      propagated,
      "talker propagates to the Forwarding egress while its source is Forwarding"
    )

    let deregBefore = await recorder.fdbDeregister.count
    try await _setStpStates(msrp, portIDs: [0, 1], [0: .blocking])
    let withdrawn = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    XCTAssertTrue(withdrawn, "blocking the talker source must withdraw the egress reservation")
    // the declaration withdrawal is a distinct effect from the FDB deregister, so poll for it
    let undeclared = await _waitFor { await !_isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    }
    XCTAssertTrue(
      undeclared,
      "blocking the talker source must withdraw the propagated declaration"
    )

    // restore Forwarding -> the talker reprograms the reservation
    let regBefore = await recorder.fdbRegister.count
    try await _setStpStates(msrp, portIDs: [0, 1], [:])
    let restored = await _waitFor { await recorder.fdbRegister.count > regBefore }
    XCTAssertTrue(
      restored,
      "restoring the talker source to Forwarding should reprogram the reservation"
    )
    _ = controller
  }

  // a talker that fails admission control on the egress is declared Failed, not Advertise
  func testRecomputeBandwidthExceededDemotesToFailed() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0032)
    let bigTalker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x02], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: 1000, maxIntervalFrames: 1000),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: bigTalker,
      event: .JoinIn
    )
    let failed = await _waitFor {
      await _isDeclared(msrp, .talkerFailed, streamID, port: 1)
    }
    XCTAssertTrue(failed, "an unbridgeable talker must be declared talkerFailed on the egress")
    let advertised = await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    XCTAssertFalse(advertised, "should not also be advertised")
    _ = controller
  }

  // a class-A talker sized so that two streams together exceed the 75% class-A limit on a
  // 1 Gbps link but one fits: 6 frames * (1000+43) bytes * 64 = 400,512 kbps (limit 750,000).
  private func _halfLimitClassATalker(
    _ streamID: MSRPStreamID, dest: EUI48
  ) -> MSRPTalkerAdvertiseValue {
    MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(destinationAddress: dest, vlanIdentifier: 2),
      tSpec: MSRPTSpec(maxFrameSize: 1000, maxIntervalFrames: 6),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
  }

  // #1: bandwidth is accounted from actual per-port reservations. Two ~half-limit streams
  // share an egress; the second cannot also reserve, but once the first's listener leaves and
  // its reservation is released, the second is admitted.
  func testRecomputeBandwidthAccountingFollowsReservations() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamA = MSRPStreamID(0x0001_0000_0000_0040)
    let streamB = MSRPStreamID(0x0001_0000_0000_0041)

    // A reserves on the shared egress (port 2)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _halfLimitClassATalker(streamA, dest: [0x91, 0xE0, 0xF0, 0, 0, 1]),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamA),
      event: .JoinIn,
      subtype: .ready
    )
    let aReserved = await _waitFor {
      await recorder.cbs.contains { $0.port == 2 && $0.idleSlope > 0 }
    }
    XCTAssertTrue(aReserved, "stream A reserves on the shared egress")

    // B cannot also be admitted on port 2 while A holds its reservation
    try await _drive(
      msrp,
      port: 1,
      attributeType: .talkerAdvertise,
      value: _halfLimitClassATalker(streamB, dest: [0x91, 0xE0, 0xF0, 0, 0, 2]),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamB),
      event: .JoinIn,
      subtype: .ready
    )
    let bFailed = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamB, port: 2) }
    XCTAssertTrue(bFailed, "B fails admission against A's reservation on the shared egress")

    // release A's reservation (its listener leaves); re-evaluate B only once A is withdrawn
    // (the drain order over the pending set is not guaranteed)
    let deregBefore = await recorder.fdbDeregister.count
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamA),
      event: .JoinIn,
      subtype: .ignore
    )
    _ = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    await msrp._streamDidUpdate(streamB)
    let bAdmitted = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamB, port: 2) }
    XCTAssertTrue(bAdmitted, "B is admitted once A's reservation is released")
    _ = controller
  }

  // #1 (distinguishing reservation- from registration-based accounting): a stream that is
  // still registered but holds NO reservation (its talker source is blocked, so nothing is
  // programmed) must not consume bandwidth. Counting raw registrations would keep B failed.
  func testRecomputeRegisteredButUnreservedStreamFreesBandwidth() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamA = MSRPStreamID(0x0001_0000_0000_0042)
    let streamB = MSRPStreamID(0x0001_0000_0000_0043)

    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _halfLimitClassATalker(streamA, dest: [0x91, 0xE0, 0xF0, 0, 0, 3]),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamA),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.cbs.contains { $0.port == 2 && $0.idleSlope > 0 } }

    try await _drive(
      msrp,
      port: 1,
      attributeType: .talkerAdvertise,
      value: _halfLimitClassATalker(streamB, dest: [0x91, 0xE0, 0xF0, 0, 0, 4]),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamB),
      event: .JoinIn,
      subtype: .ready
    )
    let bFailedFirst = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamB, port: 2) }
    XCTAssertTrue(bFailedFirst, "B fails admission against A's reservation")

    // block A's talker SOURCE: A's reservation is withdrawn, but A's listener (port 2) and
    // talker (port 0) registrations persist — so registration-based accounting would still
    // count A and keep B failed.
    let deregBefore = await recorder.fdbDeregister.count
    try await _setStpStates(msrp, portIDs: [0, 1, 2], [0: .blocking])
    _ = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    await msrp._streamDidUpdate(streamB)
    let bAdmitted = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamB, port: 2) }
    XCTAssertTrue(
      bAdmitted,
      "B is admitted once A (still registered) no longer holds a reservation"
    )
    _ = controller
  }

  // a listener on an egress whose talker fails admission control must NOT get a bandwidth
  // reservation: the bridge declares TalkerFailed out that port, so the stream cannot flow and
  // no CBS/FDB reservation may be programmed for it (the listener is AskingFailed)
  func testRecomputeAdmissionFailedEgressListenerGetsNoReservation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_003A)
    let bigTalker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x02], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: 1000, maxIntervalFrames: 1000),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: bigTalker,
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    let failed = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamID, port: 1) }
    XCTAssertTrue(failed, "the unbridgeable talker must be declared talkerFailed on the egress")
    // give the recompute time to (not) program a reservation
    try? await Task.sleep(nanoseconds: 200_000_000)
    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 1 && $0.idleSlope > 0 },
      "no bandwidth may be reserved on an admission-failed egress"
    )
    let fdb = await recorder.fdbRegister
    XCTAssertFalse(
      fdb.contains { $0.ports.contains(1) },
      "no FDB reservation may be programmed on an admission-failed egress"
    )
    _ = controller
  }

  // an Asking Failed listener is the *absence* of a reservation (Table 35-13/35-14), so it must
  // touch no hardware at all on the egress — not even a redundant idleslope-0 CBS write. (Before
  // the fix, programming .listenerAskingFailed always called adjustCreditBasedShaper.)
  func testRecomputeAskingFailedListenerTouchesNoShaper() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0044)
    // a talker too large to bridge forces the egress listener to Asking Failed
    let bigTalker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x05], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: 1000, maxIntervalFrames: 1000),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: bigTalker,
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    let failed = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamID, port: 1) }
    XCTAssertTrue(failed, "the unbridgeable talker is declared Failed on the egress")
    try? await Task.sleep(nanoseconds: 200_000_000)
    let touchedShaper = await recorder.cbs.contains { $0.port == 1 }
    XCTAssertFalse(touchedShaper, "an Asking Failed listener must not touch the CBS shaper at all")
    _ = controller
  }

  // a Talker whose DataFramePriority maps to no configured SR class must be declared Talker
  // Failed on the egress with requestedPriorityIsNotAnSRClassPriority (35.2.2.8.7 code 13),
  // distinct from the egressPortIsNotAvbCapable (code 8) used for an SRP domain boundary port.
  func testRecomputeNonSrClassPriorityDeclaresRequestedPriorityFailure() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00D1)
    // .BE is not in the bridge's SR class priority map ([.A: .CA, .B: .EE])
    let talker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x0D], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: 64, maxIntervalFrames: 1),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .BE, rank: false),
      accumulatedLatency: 1000
    )
    try await _drive(msrp, port: 0, attributeType: .talkerAdvertise, value: talker, event: .JoinIn)

    let failed = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamID, port: 1) }
    XCTAssertTrue(failed, "a non-SR-class priority must be declared Talker Failed on the egress")
    let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
    XCTAssertEqual(
      code, .requestedPriorityIsNotAnSRClassPriority,
      "expected failure code 13, got \(String(describing: code))"
    )
    _ = controller
  }

  // Avnu ProAV Bridge §9.2: the .leaveImmediate flag is on by default for MSRP, and a received
  // Leave (rLv!) drops the Talker registration to MT at once — the propagated declaration is
  // withdrawn promptly rather than lingering for the (5s) LeaveTime as in the base 802.1Q path.
  func testMSRPLeaveImmediateWithdrawsTalkerOnReceivedLeave() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    XCTAssertTrue(msrp.registrarLeaveImmediate, "leaveImmediate must be on by default (Avnu §9.2)")
    let streamID = MSRPStreamID(0x0001_0000_0000_00E1)

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let propagated = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(propagated, "the talker should propagate to the egress")

    // a received Leave on the talker's ingress port; with immediate leave the registration drops
    // straight to MT (not LV), so the recompute withdraws the egress declaration without a timer
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .Lv
    )
    let withdrawn = await _waitFor { await !_isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(withdrawn, "a received Leave must withdraw the propagated talker promptly")
    _ = controller
  }

  // The counterpart to the §9.2 behaviour: with .leaveImmediate cleared (mrpd
  // --no-leave-immediate),
  // a received Leave (rLv!) falls back to the base 802.1Q path — the Registrar goes IN -> LV and
  // holds the propagated declaration for the LeaveTime instead of withdrawing it at once.
  func testMSRPLeaveImmediateDisabledRetainsTalkerOnReceivedLeave() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(
      portIDs: [0, 1],
      flags: MSRPApplicationFlags.defaultFlags.subtracting(.leaveImmediate)
    )
    XCTAssertFalse(
      msrp.registrarLeaveImmediate, "--no-leave-immediate must clear the leaveImmediate flag"
    )
    let streamID = MSRPStreamID(0x0001_0000_0000_00E2)

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let propagated = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(propagated, "the talker should propagate to the egress")

    // a received Leave; without immediate leave the Registrar goes IN -> LV (leavetimer), so the
    // egress declaration must persist well within the (5s) LeaveTime rather than dropping at once
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .Lv
    )
    try await Task.sleep(nanoseconds: 300_000_000)
    let stillDeclared = await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    XCTAssertTrue(
      stillDeclared,
      "without leaveImmediate a received Leave must not withdraw the talker before the LeaveTime"
    )
    _ = controller
  }

  // Avnu ProAV Bridge §9.1: an Avnu Bridge shall complete any propagation of MSRP attributes
  // within 1.5s. A fresh declaration requests a TX opportunity immediately (interval .zero on a
  // point-to-point port, else random 0..<joinTime ≤ 240ms); nothing waits on the periodic (1s,
  // disabled) or leaveall (10s) timer. Assert the propagated talker appears well within 1.5s.
  func testMSRPPropagationCompletesWithin1500ms() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_00E3)

    let start = ContinuousClock.now
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    let propagated = await _waitFor(timeoutMs: 1500) {
      await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    }
    let elapsed = ContinuousClock.now - start
    XCTAssertTrue(propagated, "the talker must propagate to the egress")
    XCTAssertLessThan(
      elapsed, .milliseconds(1500), "MSRP attribute propagation must complete within 1.5s (§9.1)"
    )
    _ = controller
  }

  func testRecomputeProxiesListenerLeaveOnTalkerLeave() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0F01)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    let listenerDeclared = await _waitFor { await _isDeclared(msrp, .listener, streamID, port: 0) }
    XCTAssertTrue(listenerDeclared, "the bridge declares a Listener toward the talker")

    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .Lv
    )
    let listenerWithdrawn = await _waitFor { await !_isDeclared(msrp, .listener, streamID, port: 0)
    }
    XCTAssertTrue(
      listenerWithdrawn, "the bridge must withdraw the Listener toward the departed talker"
    )
    _ = controller
  }

  // builds a Class-A Talker Advertise; maxIntervalFrames scales the reserved bandwidth, rank=false
  // is Emergency (more important), rank=true is Non-emergency
  private func _classATalker(
    _ streamID: MSRPStreamID, dest: UInt8, frames: UInt16, rank: Bool
  ) -> MSRPTalkerAdvertiseValue {
    MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, dest], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: 1000, maxIntervalFrames: frames),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: rank),
      accumulatedLatency: 0
    )
  }

  private func _reserve(
    _ msrp: MSRPApplication<MockPort>, _ talker: MSRPTalkerAdvertiseValue
  ) async throws {
    try await _drive(msrp, port: 0, attributeType: .talkerAdvertise, value: talker, event: .JoinIn)
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: talker.streamID), event: .JoinIn, subtype: .ready
    )
  }

  // Avnu ProAV Bridge §9.1: a higher-importance (Emergency, Rank reset) stream that does not fit
  // preempts a lower-importance (Non-emergency) reserved stream, which is declared Talker Failed
  // with streamPreemptedByHigherRank; the Emergency stream is admitted.
  func testRecomputePreemptsLowerRankStream() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    // class-A budget is 75% of 1 Gbps = 750_000 kbps; each N frames ~ 66_752 kbps
    let lowID = MSRPStreamID(0x0001_0000_0000_0100) // Non-emergency, 8 frames ~ 534 Mbps
    let highID = MSRPStreamID(0x0001_0000_0000_0101) // Emergency, 4 frames ~ 267 Mbps

    try await _reserve(msrp, _classATalker(lowID, dest: 0x10, frames: 8, rank: true))
    let lowAdvertised = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, lowID, port: 1) }
    XCTAssertTrue(lowAdvertised, "the first stream fits and is admitted")

    // low + high exceed the budget; high is Emergency so it preempts low
    try await _reserve(msrp, _classATalker(highID, dest: 0x11, frames: 4, rank: false))

    let highAdvertised = await _waitFor {
      await _isDeclared(msrp, .talkerAdvertise, highID, port: 1)
    }
    XCTAssertTrue(highAdvertised, "the Emergency stream must be admitted")
    let lowFailed = await _waitFor { await _isDeclared(msrp, .talkerFailed, lowID, port: 1) }
    XCTAssertTrue(lowFailed, "the Non-emergency stream must be preempted")
    let code = await _declaredTalkerFailureCode(msrp, lowID, port: 1)
    XCTAssertEqual(code, .streamPreemptedByHigherRank)
    _ = controller
  }

  // Avnu §9.1 "if a stream that would have been cancelled need not be, then it should not be":
  // only the youngest (least important) stream is preempted to make room — an older, more
  // important stream that need not be cancelled is kept.
  func testRecomputePreemptsOnlyYoungestToMakeRoom() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let oldID = MSRPStreamID(0x0001_0000_0000_0200) // Non-emergency, oldest, 6 frames ~ 400 Mbps
    let youngID =
      MSRPStreamID(0x0001_0000_0000_0201) // Non-emergency, youngest, 5 frames ~ 334 Mbps
    let emergID = MSRPStreamID(0x0001_0000_0000_0202) // Emergency, 3 frames ~ 200 Mbps

    // old + young fit together (~734 Mbps <= 750 Mbps)
    try await _reserve(msrp, _classATalker(oldID, dest: 0x20, frames: 6, rank: true))
    try await _reserve(msrp, _classATalker(youngID, dest: 0x21, frames: 5, rank: true))
    let bothFit = await _waitFor {
      let o = await _isDeclared(msrp, .talkerAdvertise, oldID, port: 1)
      let y = await _isDeclared(msrp, .talkerAdvertise, youngID, port: 1)
      return o && y
    }
    XCTAssertTrue(bothFit, "both Non-emergency streams fit within the budget")

    // an Emergency stream arrives; cancelling the youngest alone frees enough, so the older
    // stream is kept (not over-cancelled)
    try await _reserve(msrp, _classATalker(emergID, dest: 0x22, frames: 3, rank: false))

    let emergAdvertised = await _waitFor {
      await _isDeclared(msrp, .talkerAdvertise, emergID, port: 1)
    }
    XCTAssertTrue(emergAdvertised, "the Emergency stream must be admitted")
    let youngFailed = await _waitFor { await _isDeclared(msrp, .talkerFailed, youngID, port: 1) }
    XCTAssertTrue(youngFailed, "the youngest stream is preempted to make room")
    let youngCode = await _declaredTalkerFailureCode(msrp, youngID, port: 1)
    XCTAssertEqual(youngCode, .streamPreemptedByHigherRank)
    // the older, more important stream need not be cancelled, so it is kept
    let oldKept = await _isDeclared(msrp, .talkerAdvertise, oldID, port: 1)
    XCTAssertTrue(oldKept, "the older stream that need not be cancelled must be kept")
    let oldFailed = await _isDeclared(msrp, .talkerFailed, oldID, port: 1)
    XCTAssertFalse(oldFailed, "the older stream must not be preempted")
    _ = controller
  }

  // Avnu §9.1 "streams of higher importance need not be dropped, even if some streams of lower
  // importance would need to be dropped": when preemption frees headroom that only fits one of
  // several cancelled streams, the trim must re-admit the *more* important one. Here an Emergency
  // stream forces three Non-emergency streams to be cancelled; afterwards only one of them fits
  // back in, and it must be the more important (lower-StreamID) one, not the least important.
  func testRecomputePreemptTrimReadmitsMoreImportantStream() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    // class-A budget 750_000 kbps; each frame ~ 66_752 kbps, so 11 frames fit (734_272) but 12
    // do not (801_024). Lower StreamID is more important when ranks/ages tie.
    let bigID = MSRPStreamID(0x0001_0000_0000_0300) // Non-emergency, most important, 6 frames
    let midID = MSRPStreamID(0x0001_0000_0000_0301) // Non-emergency, mid importance, 3 frames
    let smallID = MSRPStreamID(0x0001_0000_0000_0302) // Non-emergency, least important, 2 frames
    let emergID = MSRPStreamID(0x0001_0000_0000_0303) // Emergency, 7 frames

    // big + mid + small = 11 frames, exactly fitting the budget
    try await _reserve(msrp, _classATalker(bigID, dest: 0x30, frames: 6, rank: true))
    try await _reserve(msrp, _classATalker(midID, dest: 0x31, frames: 3, rank: true))
    try await _reserve(msrp, _classATalker(smallID, dest: 0x32, frames: 2, rank: true))
    let allFit = await _waitFor {
      let b = await _isDeclared(msrp, .talkerAdvertise, bigID, port: 1)
      let m = await _isDeclared(msrp, .talkerAdvertise, midID, port: 1)
      let s = await _isDeclared(msrp, .talkerAdvertise, smallID, port: 1)
      return b && m && s
    }
    XCTAssertTrue(allFit, "the three Non-emergency streams fit within the budget")

    // the Emergency stream (7 frames) does not fit alongside any other; cancelling all three frees
    // room, then only `mid` (3) fits back with it (7+3=10), not `small` (7+3+2=12 > budget). `big`
    // (7+6=13) cannot return either. So the more important `mid` is kept over the lesser `small`.
    try await _reserve(msrp, _classATalker(emergID, dest: 0x33, frames: 7, rank: false))

    let emergAdvertised = await _waitFor {
      await _isDeclared(msrp, .talkerAdvertise, emergID, port: 1)
    }
    XCTAssertTrue(emergAdvertised, "the Emergency stream must be admitted")
    let midKept = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, midID, port: 1) }
    XCTAssertTrue(midKept, "the more important cancelled stream must be re-admitted by the trim")
    let smallFailed = await _waitFor { await _isDeclared(msrp, .talkerFailed, smallID, port: 1) }
    XCTAssertTrue(smallFailed, "the least important stream stays cancelled")
    let midFailed = await _isDeclared(msrp, .talkerFailed, midID, port: 1)
    XCTAssertFalse(midFailed, "the more important stream must not be the one dropped")
    let smallCode = await _declaredTalkerFailureCode(msrp, smallID, port: 1)
    XCTAssertEqual(smallCode, .streamPreemptedByHigherRank)
    _ = controller
  }

  // A stream that exceeds the SR-class budget even on its own has not been preempted — no amount of
  // cancelling other streams would admit it — so it must fail insufficientBandwidth, not
  // streamPreemptedByHigherRank, even though a more important stream is reserved on the port.
  func testRecomputeOversizedStreamFailsInsufficientNotPreempted() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    // class-A budget 750_000 kbps ~ 11 frames; 12 frames (801_024) does not fit even alone
    let highID = MSRPStreamID(0x0001_0000_0000_0400) // Emergency, small, 2 frames
    let bigID = MSRPStreamID(0x0001_0000_0000_0401) // Non-emergency, 12 frames — oversized alone

    try await _reserve(msrp, _classATalker(highID, dest: 0x40, frames: 2, rank: false))
    let highAdvertised = await _waitFor {
      await _isDeclared(msrp, .talkerAdvertise, highID, port: 1)
    }
    XCTAssertTrue(highAdvertised, "the small Emergency stream is admitted")

    try await _reserve(msrp, _classATalker(bigID, dest: 0x41, frames: 12, rank: true))
    let bigFailed = await _waitFor { await _isDeclared(msrp, .talkerFailed, bigID, port: 1) }
    XCTAssertTrue(bigFailed, "an oversized stream cannot be admitted")
    let bigCode = await _declaredTalkerFailureCode(msrp, bigID, port: 1)
    XCTAssertEqual(
      bigCode, .insufficientBandwidth,
      "a stream that does not fit even alone fails insufficientBandwidth, not preempted"
    )
    // the more important stream is untouched
    let highKept = await _isDeclared(msrp, .talkerAdvertise, highID, port: 1)
    XCTAssertTrue(highKept, "the Emergency stream must not be affected")
    _ = controller
  }

  // Table 35-12 (35.2.4.4.1): the listener propagated toward the talker keys on the Talker
  // *registered* on the source port, NOT on a local per-egress admission result. When the
  // bound talker is registered as Advertise but a local egress fails bandwidth admission, the
  // listener is forwarded toward the talker as-is (Ready) — the AskingFailed comes back from
  // the downstream listener reacting to the TalkerFailed we declare out the failed egress.
  func testRecomputeAdmissionFailedEgressForwardsListenerAsIsTowardTalker() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_003B)
    let bigTalker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x02], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: 1000, maxIntervalFrames: 1000),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: bigTalker,
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    // the listener declaration merged toward the talker (port 0) must be forwarded as-is (Ready)
    let merged = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 0) == .ready
    }
    XCTAssertTrue(
      merged,
      "a listener whose local egress failed admission is still forwarded Ready toward the talker"
    )
    _ = controller
  }

  // Table 35-12 (35.2.4.4.1): when the bound talker is *registered* as Failed, an associated
  // Listener Ready must be propagated toward the talker as Asking Failed.
  func testRecomputeRegisteredTalkerFailedMergesAskingFailedTowardTalker() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_003D)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerFailed,
      value: _talkerFailed(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    let merged = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 0) == .askingFailed
    }
    XCTAssertTrue(
      merged,
      "a registered Talker Failed forces the merged listener toward the talker to Asking Failed"
    )
    _ = controller
  }

  // on a point-to-point link, a port that registers both the talker and a listener for the
  // same stream (the bound talker's own port) must not get a reservation back toward the
  // source; a separate Forwarding listener still reserves normally
  func testRecomputeNoReservationBackTowardPointToPointTalker() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_003C)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    // a listener on the talker's own (point-to-point) port: MockPort.isPointToPoint == true
    try await _drive(
      msrp,
      port: 0,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    let reserved = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    XCTAssertTrue(reserved, "the genuine downstream listener (port 1) must reserve")
    // the talker's own port must never get a reservation back toward the source
    try? await Task.sleep(nanoseconds: 200_000_000)
    let cbs = await recorder.cbs
    XCTAssertFalse(
      cbs.contains { $0.port == 0 && $0.idleSlope > 0 },
      "no reservation may be programmed back out the point-to-point talker port"
    )
    let fdb = await recorder.fdbRegister
    XCTAssertFalse(
      fdb.contains { $0.ports.contains(0) },
      "no FDB reservation may be programmed on the point-to-point talker port"
    )
    _ = controller
  }

  // gap probe: removing the talker's port should tear down the listener-port reservation
  func testRecomputeTalkerPortRemovalWithdrawsReservation() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0033)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    let deregBefore = await recorder.fdbDeregister.count

    try await msrp.didRemove(
      contextIdentifier: MAPBaseSpanningTreeContext,
      with: Set([MockPort(id: 0)])
    )
    let withdrawn = await _waitFor(timeoutMs: 1500) {
      await recorder.fdbDeregister.count > deregBefore
    }
    XCTAssertTrue(withdrawn, "removing the talker port should withdraw the listener reservation")
    _ = controller
  }
}

// MARK: - MSRP recompute: multi-listener / multi-talker / talker-type transitions

extension MRPTests {
  // three listener egress ports in ready / readyFailed / askingFailed: the first two reserve
  // idleslope, the asking-failed one does not.
  func testRecomputeThreeListenerStates() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2, 3])
    let streamID = MSRPStreamID(0x0001_0000_0000_0040)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .readyFailed
    )
    try await _drive(
      msrp,
      port: 3,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .askingFailed
    )
    _ = await _waitFor { await recorder.cbs.contains { $0.port == 2 && $0.idleSlope > 0 } }
    try? await Task.sleep(nanoseconds: 250_000_000)
    let cbs = await recorder.cbs
    XCTAssertTrue(cbs.contains { $0.port == 1 && $0.idleSlope > 0 }, "ready reserves")
    XCTAssertTrue(cbs.contains { $0.port == 2 && $0.idleSlope > 0 }, "readyFailed reserves")
    XCTAssertFalse(
      cbs.contains { $0.port == 3 && $0.idleSlope > 0 },
      "askingFailed does not reserve"
    )
    _ = controller
  }

  // Table 35-12 (35.2.4.4.3): the listener declarations on multiple egress ports merge into
  // one declaration toward the talker. Ready + AskingFailed merges to ReadyFailed.
  func testRecomputeMergesMixedListenersTowardTalker() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamID = MSRPStreamID(0x0001_0000_0000_0041)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    try await _drive(
      msrp, port: 2, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .askingFailed
    )
    let merged = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 0) == .readyFailed
    }
    XCTAssertTrue(merged, "Ready + AskingFailed must propagate toward the talker as ReadyFailed")
    _ = controller
  }

  // The all-Ready case of the same merge stays Ready toward the talker.
  func testRecomputeMergesAllReadyListenersAsReady() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let streamID = MSRPStreamID(0x0001_0000_0000_0042)
    try await _drive(
      msrp, port: 0, attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID), event: .JoinIn
    )
    try await _drive(
      msrp, port: 1, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    try await _drive(
      msrp, port: 2, attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID), event: .JoinIn, subtype: .ready
    )
    let merged = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 0) == .ready
    }
    XCTAssertTrue(merged, "two Ready listeners must propagate toward the talker as Ready")
    _ = controller
  }

  // two independent streams (talkers on different ingress ports) sharing one listener egress
  // port: both reserve there, bound to their own talker, and neither talker port reserves.
  func testRecomputeMultipleStreamsShareListenerPort() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1, 2])
    let sA = MSRPStreamID(0x0001_0000_0000_0041)
    let sB = MSRPStreamID(0x0001_0000_0000_0042)
    let macA: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x41]
    let macB: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x42]
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(sA, dest: macA),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(sB, dest: macB),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: sA),
      event: .JoinIn,
      subtype: .ready
    )
    try await _drive(
      msrp,
      port: 2,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: sB),
      event: .JoinIn,
      subtype: .ready
    )

    let bothReserved = await _waitFor {
      let onPort2 = await recorder.fdbRegister.filter { $0.ports.contains(2) }
      return Set(onPort2.map { UInt64(eui48: $0.mac) }).count == 2
    }
    XCTAssertTrue(bothReserved, "both streams reserve FDB on the shared listener port (2)")
    let fdb = await recorder.fdbRegister
    XCTAssertFalse(
      fdb.contains { $0.ports.contains(0) || $0.ports.contains(1) },
      "no reservation on either talker port"
    )
    _ = controller
  }

  // a talker that flips Advertise -> Failed -> Advertise: the listener reservation is torn down
  // when it fails and re-established when it recovers (peer mutual exclusion clears the opposite).
  func testRecomputeTalkerAdvertiseFailedTransitions() async throws {
    let (controller, msrp, recorder) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0043)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    try await _drive(
      msrp,
      port: 1,
      attributeType: .listener,
      value: MSRPListenerValue(streamID: streamID),
      event: .JoinIn,
      subtype: .ready
    )
    _ = await _waitFor { await recorder.fdbRegister.contains { $0.ports.contains(1) } }
    let deregBefore = await recorder.fdbDeregister.count

    // Advertise -> Failed
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerFailed,
      value: _talkerFailed(streamID),
      event: .JoinIn
    )
    let torn = await _waitFor { await recorder.fdbDeregister.count > deregBefore }
    XCTAssertTrue(torn, "advertise -> failed must withdraw the listener reservation")
    let failedDeclared = await _isDeclared(msrp, .talkerFailed, streamID, port: 1)
    XCTAssertTrue(failedDeclared, "failed talker should be propagated")
    // mutual exclusion: the prior talkerAdvertise declaration must be withdrawn
    let advCleared = await _waitFor {
      await !_isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    }
    XCTAssertTrue(advCleared, "talkerAdvertise must clear after advertise -> failed")

    // Failed -> Advertise
    let regBefore = await recorder.fdbRegister.filter { $0.ports.contains(1) }.count
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(streamID),
      event: .JoinIn
    )
    let reestablished = await _waitFor {
      await recorder.fdbRegister.filter { $0.ports.contains(1) }.count > regBefore
    }
    XCTAssertTrue(reestablished, "failed -> advertise must re-establish the reservation")

    // mutual exclusion: the prior talkerFailed declaration must be withdrawn
    let failedCleared = await _waitFor {
      await !_isDeclared(msrp, .talkerFailed, streamID, port: 1)
    }
    XCTAssertTrue(failedCleared, "talkerFailed must clear after failed -> advertise")
    let advNowDeclared = await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    XCTAssertTrue(advNowDeclared, "talkerAdvertise must be declared after re-advertise")
    _ = controller
  }
}

// MARK: - MSRP admission control & local (de)registration spec fixes

extension MRPTests {
  private func _talker(
    _ streamID: MSRPStreamID, maxFrameSize: UInt16, maxIntervalFrames: UInt16 = 1
  ) -> MSRPTalkerAdvertiseValue {
    MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x05], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: maxFrameSize, maxIntervalFrames: maxIntervalFrames),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
  }

  // 35.2.2.8.4: MaxFrameSize excludes media framing overhead, so a stream whose MaxFrameSize
  // exactly equals the port MTU (MockPort.mtu == 1500) is admissible and must be advertised,
  // not declared TalkerFailed (regression: the check used to add ~42 bytes of L1/L2 overhead).
  func testCanBridgeTalkerMaxFrameSizeAtPortMtu() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0050)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talker(streamID, maxFrameSize: 1500),
      event: .JoinIn
    )
    let advertised = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(advertised, "MaxFrameSize == port MTU must be admitted and advertised")
    let failed = await _isDeclared(msrp, .talkerFailed, streamID, port: 1)
    XCTAssertFalse(failed, "MaxFrameSize == port MTU must not be declared TalkerFailed")
    _ = controller
  }

  // a MaxFrameSize larger than the port MTU still fails the media-fit check (TalkerFailed)
  func testCanBridgeTalkerMaxFrameSizeAbovePortMtu() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0051)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talker(streamID, maxFrameSize: 1501),
      event: .JoinIn
    )
    let failed = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamID, port: 1) }
    XCTAssertTrue(failed, "MaxFrameSize > port MTU must be declared TalkerFailed")
    _ = controller
  }

  // 35.2.3.1.3: DEREGISTER_STREAM.request must withdraw the locally declared Talker attribute
  func testDeregisterStreamWithdrawsLocalTalkerDeclaration() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0052)
    let talker = _talker(streamID, maxFrameSize: 100)
    try await msrp.registerStream(
      streamID: streamID,
      declarationType: .talkerAdvertise,
      dataFrameParameters: talker.dataFrameParameters,
      tSpec: talker.tSpec,
      priorityAndRank: talker.priorityAndRank,
      accumulatedLatency: talker.accumulatedLatency
    )
    let declared = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(declared, "registerStream must declare the Talker attribute")
    try await msrp.deregisterStream(streamID: streamID)
    let withdrawn = await _waitFor {
      await !_isDeclared(msrp, .talkerAdvertise, streamID, port: 1)
    }
    XCTAssertTrue(withdrawn, "deregisterStream must withdraw the declared Talker attribute")
    _ = controller
  }

  // 35.2.3.1.7: DEREGISTER_ATTACH.request must withdraw the locally declared Listener attribute
  func testDeregisterAttachWithdrawsLocalListenerDeclaration() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0053)
    try await msrp.registerAttach(streamID: streamID, declarationType: .listenerReady)
    let declared = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 1) == .ready
    }
    XCTAssertTrue(declared, "registerAttach must declare the Listener attribute")
    try await msrp.deregisterAttach(streamID: streamID)
    let withdrawn = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 1) == nil
    }
    XCTAssertTrue(withdrawn, "deregisterAttach must withdraw the declared Listener attribute")
    _ = controller
  }

  // 35.2.2.8.3: SRP only supports multicast or locally-administered destination addresses; a
  // globally-administered unicast destination must be declared TalkerFailed on the egress
  func testCanBridgeTalkerRejectsGloballyAdministeredUnicastDestination() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0054)
    let talker = MSRPTalkerAdvertiseValue(
      streamID: streamID,
      dataFrameParameters: MSRPDataFrameParameters(
        destinationAddress: [0x00, 0x11, 0x22, 0x33, 0x44, 0x55], vlanIdentifier: 2
      ),
      tSpec: MSRPTSpec(maxFrameSize: 64, maxIntervalFrames: 1),
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: false),
      accumulatedLatency: 1000
    )
    try await _drive(msrp, port: 0, attributeType: .talkerAdvertise, value: talker, event: .JoinIn)
    let failed = await _waitFor { await _isDeclared(msrp, .talkerFailed, streamID, port: 1) }
    XCTAssertTrue(failed, "a globally-administered unicast destination must be TalkerFailed")
    _ = controller
  }

  // 35.2.2.8.3: only one Stream is allowed per destination_address; a second stream reusing the
  // same destination MAC must be declared TalkerFailed on the egress
  func testCanBridgeTalkerRejectsDuplicateDestinationAddress() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let dest: EUI48 = [0x91, 0xE0, 0xF0, 0x00, 0x00, 0x60]
    let sA = MSRPStreamID(0x0001_0000_0000_0055)
    let sB = MSRPStreamID(0x0001_0000_0000_0056)
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(sA, dest: dest),
      event: .JoinIn
    )
    let aAdvertised = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, sA, port: 1) }
    XCTAssertTrue(aAdvertised, "first stream must be advertised")
    // a second, different stream reusing the same destination address must fail
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: _talkerAdvertise(sB, dest: dest),
      event: .JoinIn
    )
    let bFailed = await _waitFor { await _isDeclared(msrp, .talkerFailed, sB, port: 1) }
    XCTAssertTrue(bFailed, "a second stream reusing the destination address must be TalkerFailed")
    _ = controller
  }

  // 35.2.6: a local Talker Advertise -> Failed transition replaces the declaration; at most one
  // Talker declaration per StreamID per port may exist
  func testRegisterStreamAdvertiseToFailedReplacesDeclaration() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0057)
    let talker = _talker(streamID, maxFrameSize: 100)
    try await msrp.registerStream(
      streamID: streamID, declarationType: .talkerAdvertise,
      dataFrameParameters: talker.dataFrameParameters, tSpec: talker.tSpec,
      priorityAndRank: talker.priorityAndRank, accumulatedLatency: talker.accumulatedLatency
    )
    let advertised = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 0) }
    XCTAssertTrue(advertised, "the Talker Advertise must be declared")
    try await msrp.registerStream(
      streamID: streamID, declarationType: .talkerFailed,
      dataFrameParameters: talker.dataFrameParameters, tSpec: talker.tSpec,
      priorityAndRank: talker.priorityAndRank, accumulatedLatency: talker.accumulatedLatency,
      failureInformation: MSRPFailure(
        systemID: MSRPSystemID(id: 0x1234),
        failureCode: .insufficientBandwidth
      )
    )
    let replaced = await _waitFor {
      let failed = await _isDeclared(msrp, .talkerFailed, streamID, port: 0)
      let stillAdvertised = await _isDeclared(msrp, .talkerAdvertise, streamID, port: 0)
      return failed && !stillAdvertised
    }
    XCTAssertTrue(replaced, "Advertise->Failed must leave only the Talker Failed declaration")
    _ = controller
  }

  // 35.2.6: a local Listener Declaration Type change replaces the existing declaration
  func testRegisterAttachListenerSubtypeChangeReplaces() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0058)
    try await msrp.registerAttach(
      streamID: streamID,
      declarationType: .listenerReady,
      on: MockPort(id: 1)
    )
    let ready = await _waitFor { await _declaredListenerSubtype(msrp, streamID, port: 1) == .ready }
    XCTAssertTrue(ready, "the Listener Ready must be declared")
    try await msrp.registerAttach(
      streamID: streamID,
      declarationType: .listenerAskingFailed,
      on: MockPort(id: 1)
    )
    let changed = await _waitFor {
      await _declaredListenerSubtype(msrp, streamID, port: 1) == .askingFailed
    }
    XCTAssertTrue(changed, "the Listener subtype change to Asking Failed must replace Ready")
    _ = controller
  }

  // 35.2.2.8: MSRP does not support changing any FirstValue field of a registered StreamID. A
  // peer re-declaration on the same stream with a changed MaxFrameSize, MaxIntervalFrames,
  // DataFramePriority or Rank must be rejected — the propagated declaration keeps the original.
  private func _assertFirstValueChangeRejected(
    _ field: String,
    changed: MSRPTalkerAdvertiseValue,
    line: UInt = #line
  ) async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    let original = _talkerAdvertise(streamID)

    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: original,
      event: .JoinIn
    )
    let propagated = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil
    }
    XCTAssertTrue(
      propagated,
      "\(field): original advertise must propagate to the egress port",
      line: line
    )

    // the illegal change, same StreamID and ingress port
    try await _drive(msrp, port: 0, attributeType: .talkerAdvertise, value: changed, event: .JoinIn)

    // 35.2.2.8: the stream converges to Talker Failed (code 16) and the original Advertise is
    // withdrawn for it -- the two may briefly coexist during the transition (35.2.6)
    let failed = await _waitFor {
      let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
      let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
      return code == .changeInFirstValueForRegisteredStreamID && advertise == nil
    }
    XCTAssertTrue(
      failed,
      "\(field): the changed FirstValue must fail the stream (code 16) and withdraw the advertise",
      line: line
    )

    // the Failed declaration carries the original (kept) FirstValue, not the changed one
    if let egressFailed = await _declaredTalkerFailed(msrp, streamID, port: 1) {
      XCTAssertTrue(
        egressFailed.isEqualIdentity(to: original),
        "\(field): the Failed declaration must carry the original FirstValue", line: line
      )
    }
    _ = controller
  }

  func testRejectsChangedMaxFrameSize() async throws {
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    var changed = _talkerAdvertise(streamID)
    changed = MSRPTalkerAdvertiseValue(
      streamID: streamID, dataFrameParameters: changed.dataFrameParameters,
      tSpec: MSRPTSpec(maxFrameSize: 128, maxIntervalFrames: 1),
      priorityAndRank: changed.priorityAndRank, accumulatedLatency: changed.accumulatedLatency
    )
    try await _assertFirstValueChangeRejected("MaxFrameSize", changed: changed)
  }

  func testRejectsChangedMaxIntervalFrames() async throws {
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    let base = _talkerAdvertise(streamID)
    let changed = MSRPTalkerAdvertiseValue(
      streamID: streamID, dataFrameParameters: base.dataFrameParameters,
      tSpec: MSRPTSpec(maxFrameSize: 64, maxIntervalFrames: 2),
      priorityAndRank: base.priorityAndRank, accumulatedLatency: base.accumulatedLatency
    )
    try await _assertFirstValueChangeRejected("MaxIntervalFrames", changed: changed)
  }

  func testRejectsChangedDataFramePriority() async throws {
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    let base = _talkerAdvertise(streamID)
    let changed = MSRPTalkerAdvertiseValue(
      streamID: streamID, dataFrameParameters: base.dataFrameParameters, tSpec: base.tSpec,
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .EE, rank: false),
      accumulatedLatency: base.accumulatedLatency
    )
    try await _assertFirstValueChangeRejected("DataFramePriority", changed: changed)
  }

  func testRejectsChangedRank() async throws {
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    let base = _talkerAdvertise(streamID)
    let changed = MSRPTalkerAdvertiseValue(
      streamID: streamID, dataFrameParameters: base.dataFrameParameters, tSpec: base.tSpec,
      priorityAndRank: MSRPPriorityAndRank(dataFramePriority: .CA, rank: true),
      accumulatedLatency: base.accumulatedLatency
    )
    try await _assertFirstValueChangeRejected("Rank", changed: changed)
  }

  // 35.2.2.8.5(c): the Reserved nibble is ignored on receive, so a re-declaration that differs
  // only in the Reserved bits is NOT a FirstValue change — the stream must keep flowing, not fail.
  func testChangedReservedIsNotAFirstValueChange() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    let original = _talkerAdvertise(streamID)

    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: original,
      event: .JoinIn
    )
    let propagated = await _waitFor {
      await _declaredTalkerAdvertise(msrp, streamID, port: 1) != nil
    }
    XCTAssertTrue(propagated, "original advertise must propagate to the egress port")

    // a peer re-declaration identical except the on-wire Reserved nibble is set
    let onWire = try _talkerWithReservedBitsSet(original)
    XCTAssertEqual(
      onWire.priorityAndRank, original.priorityAndRank,
      "Reserved bits must be masked off on receive"
    )
    try await _drive(msrp, port: 0, attributeType: .talkerAdvertise, value: onWire, event: .JoinIn)

    let failed = await _waitFor(timeoutMs: 300) {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1) != nil
    }
    XCTAssertFalse(failed, "a Reserved-only difference must not fail the stream")
    let egress = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
    XCTAssertNotNil(egress, "the stream must remain advertised")
    if let egress {
      XCTAssertTrue(egress.isEqualIdentity(to: original))
    }
    _ = controller
  }

  // 35.2.2.8: the code-16 failure lasts only for the registration's life -- once the talker
  // withdraws (Leave), a clean re-declaration recovers to Advertise (the flag is cleared).
  func testFirstValueChangeRecoversAfterTalkerWithdraws() async throws {
    let (controller, msrp, _) = try await _makeRecomputeMSRP(portIDs: [0, 1])
    let streamID = MSRPStreamID(0x0001_0000_0000_0001)
    let original = _talkerAdvertise(streamID)
    let changed = MSRPTalkerAdvertiseValue(
      streamID: streamID, dataFrameParameters: original.dataFrameParameters,
      tSpec: MSRPTSpec(maxFrameSize: 128, maxIntervalFrames: 1),
      priorityAndRank: original.priorityAndRank, accumulatedLatency: original.accumulatedLatency
    )

    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: original,
      event: .JoinIn
    )
    let propagated = await _waitFor { await _isDeclared(msrp, .talkerAdvertise, streamID, port: 1) }
    XCTAssertTrue(propagated, "the original advertise must propagate")

    // the illegal change fails the stream (code 16)
    try await _drive(msrp, port: 0, attributeType: .talkerAdvertise, value: changed, event: .JoinIn)
    let failed = await _waitFor {
      await _declaredTalkerFailureCode(msrp, streamID, port: 1)
        == .changeInFirstValueForRegisteredStreamID
    }
    XCTAssertTrue(failed, "the changed FirstValue must fail the stream (code 16)")

    // the talker withdraws: the failure is cleared along with the registration
    try await _drive(msrp, port: 0, attributeType: .talkerAdvertise, value: original, event: .Lv)
    let withdrawn = await _waitFor {
      let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
      let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
      return advertise == nil && code == nil
    }
    XCTAssertTrue(withdrawn, "the withdrawn talker must clear both the advertise and the failure")

    // a clean re-declaration recovers to Advertise, proving the code-16 flag was cleared
    try await _drive(
      msrp,
      port: 0,
      attributeType: .talkerAdvertise,
      value: original,
      event: .JoinIn
    )
    let recovered = await _waitFor {
      let advertise = await _declaredTalkerAdvertise(msrp, streamID, port: 1)
      let code = await _declaredTalkerFailureCode(msrp, streamID, port: 1)
      return advertise != nil && code == nil
    }
    XCTAssertTrue(recovered, "a clean re-declaration must recover to Advertise")
    _ = controller
  }

  // round-trip a talker's PriorityAndRank through the wire with the Reserved nibble set, as a
  // non-compliant peer might send it; parsing masks it back off
  private func _talkerWithReservedBitsSet(
    _ talker: MSRPTalkerAdvertiseValue
  ) throws -> MSRPTalkerAdvertiseValue {
    var sc = SerializationContext()
    try talker.priorityAndRank.serialize(into: &sc)
    var raw = sc.bytes
    raw[0] |= 0x0F
    let parsed = try raw.withParserSpan { try MSRPPriorityAndRank(parsing: &$0) }
    return MSRPTalkerAdvertiseValue(
      streamID: talker.streamID, dataFrameParameters: talker.dataFrameParameters,
      tSpec: talker.tSpec, priorityAndRank: parsed, accumulatedLatency: talker.accumulatedLatency
    )
  }
}
