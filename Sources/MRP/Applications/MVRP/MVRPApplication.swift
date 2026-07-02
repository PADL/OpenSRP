//
// Copyright (c) 2024-2026 PADL Software Pty Ltd
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

import AsyncExtensions
import BinaryParsing
import IEEE802
import Logging
import Synchronization
#if RestAPI
import FlyingFox
#endif

public let MVRPEtherType: UInt16 = 0x88F5

protocol MVRPAwareBridge<P>: Bridge where P: Port {
  // fires when a port's statically-configured VLAN membership changes
  var vlanRegistrationNotifications: AnyAsyncSequence<VLANRegistrationNotification<P>> { get }

  func register(vlan: VLAN, on port: P) async throws
  func deregister(vlan: VLAN, from port: P) async throws
}

public actor MVRPApplication<P: Port>: BaseApplication, BaseApplicationEventObserver, Sendable,
  BaseApplicationContextObserver, CustomStringConvertible where P == P
{
  // for now, we only operate in the Base Spanning Tree Context
  public nonisolated var nonBaseContextsSupported: Bool { false }

  // MVRP uses the base 802.1Q leavetimer (Avnu §9.2 immediate leave is MSRP-only)
  public nonisolated var registrarLeaveImmediate: Bool { false }

  public nonisolated var validAttributeTypes: ClosedRange<AttributeType> {
    MVRPAttributeType.validAttributeTypes
  }

  // 10.12.1.3 MVRP application address
  public nonisolated var groupAddress: EUI48 { CustomerBridgeMRPGroupAddress }

  // 10.12.1.4 MVRP application EtherType
  public nonisolated var etherType: UInt16 { MVRPEtherType }

  // 10.12.1.5 MVRP ProtocolVersion
  public nonisolated var protocolVersion: ProtocolVersion { 0 }

  public nonisolated var hasAttributeListLength: Bool { false }

  let _controller: Weak<MRPController<P>>

  public nonisolated var controller: MRPController<P>? { _controller.object }

  var _participants: [MAPContextIdentifier: Set<Participant<MVRPApplication<P>>>] = [:]
  let _logger: Logger
  let _vlanExclusions: Set<VLAN>
  // statically-configured VIDs per port currently held as Registration Fixed (8.8.2).
  // Dynamic (peer-registered) VLANs must never be promoted to Registration Fixed (that
  // would ignore the peer's Leave and could loop propagation); they are excluded via
  // port.dynamicVlans (BRIDGE_VLAN_INFO_DYNAMIC, which also survives a daemon restart)
  // and _dynamicVIDs. On kernels without the flag, dynamic entries left over from a
  // previous run are indistinguishable from static configuration and will be promoted.
  private var _staticVIDs = [P.ID: Set<VLAN>]()
  // VIDs registered dynamically (by a peer) this run, tracked so they are excluded from
  // the static set even on kernels without BRIDGE_VLAN_INFO_DYNAMIC
  private var _dynamicVIDs = [P.ID: Set<VLAN>]()
  private var _vlanNotificationTask: Task<(), Error>?

  public init(controller: MRPController<P>, vlanExclusions: Set<VLAN> = []) async throws {
    _controller = Weak(controller)
    _logger = controller.logger
    _vlanExclusions = vlanExclusions
    try await controller.register(application: self)
    _vlanNotificationTask = Task { [weak self] in
      guard let self, let controller = self.controller,
            let bridge = controller.bridge as? any MVRPAwareBridge<P> else { return }
      try? await _observeVLANNotifications(bridge: bridge, controller: controller)
    }
  }

  deinit {
    _vlanNotificationTask?.cancel()
  }

  public nonisolated var description: String {
    "MVRPApplication(controller: \(controller!))"
  }

  public nonisolated var name: String { "MVRP" }

  public nonisolated func deserialize(
    attributeOfType attributeType: AttributeType,
    from input: inout ParserSpan
  ) throws -> any Value {
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      return try VLAN(parsing: &input)
    }
  }

  public nonisolated func makeNullValue(for attributeType: AttributeType) throws -> any Value {
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      return VLAN()
    }
  }

  public nonisolated func hasAttributeSubtype(for: AttributeType) -> Bool {
    false
  }

  public nonisolated func coalesceVectors(for: AttributeType) -> Bool {
    true
  }

  public nonisolated func administrativeControl(for attributeType: AttributeType) throws
    -> AdministrativeControl
  {
    .normalParticipant
  }

  public nonisolated func isRegistrationAllowed(
    for attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    on port: P
  ) -> Bool {
    true
  }

  // On receipt of an ES_REGISTER_VLAN_MEMBER service primitive, the MVRP
  // Participant issues a MAD_Join.request service primitive (10.2, 10.3). The
  // attribute_type parameter of the request carries the value of the VID
  // Vector Attribute Type (11.2.3.1.6) and the attribute_value parameter
  // carries the value of the VID parameter carried in the
  // ES_REGISTER_VLAN_MEMBER primitive.
  public func register(vlanMember: VLAN) throws {
    try join(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: vlanMember,
      isNew: false,
      for: MAPBaseSpanningTreeContext
    )
  }

  // On receipt of an ES_DEREGISTER_VLAN_MEMBER service primitive, the MVRP
  // Participant issues a MAD_Leave.request service primitive (10.2, 10.3). The
  // attribute_type parameter of the request carries the value of the VID
  // Vector Attribute Type (11.2.3.1.6) and the attribute_value parameter
  // carries the value of the VID parameter carried in the
  // ES_DEREGISTER_VLAN_MEMBER primitive.
  public func deregister(vlanMember: VLAN) throws {
    try leave(
      attributeType: MVRPAttributeType.vid.rawValue,
      attributeValue: vlanMember,
      for: MAPBaseSpanningTreeContext
    )
  }

  // Never let MVRP add/remove a port's PVID (native VLAN) or operator-excluded VLANs.
  private func _isVlanExcluded(_ vlan: VLAN, port: P) -> Bool {
    if _vlanExclusions.contains(vlan) {
      true
    } else if let pvid = port.pvid {
      vlan.vid == pvid
    } else {
      false
    }
  }

  public func periodic(for contextIdentifier: MAPContextIdentifier?) async throws {
    // 5.4.4 the Periodic Transmission state machine (10.7.10) is specifically
    // excluded from MSRP
    try apply(for: contextIdentifier) { participant in
      try participant.periodic()
    }
  }
}

extension MVRPApplication {
  // On receipt of a MAD_Join.indication whose attribute_type is equal to the
  // value of the VID Vector Attribute Type (11.2.3.1.6), the MVRP application
  // element indicates the reception Port as Registered in the Port Map of the
  // Dynamic VLAN Registration Entry for the VID indicated by the
  // attribute_value parameter. If no such entry exists, there is sufficient
  // room in the FDB, and the VID is within the range of values supported by
  // the implementation (see 9.6), then an entry is created. If not, then the
  // indication is not propagated and the registration fails.
  func onJoinIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    isNew: Bool,
    eventSource: EventSource
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MVRPAwareBridge<P> else { return }
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      let vlan = (attributeValue as! VLAN)
      guard !_isVlanExcluded(vlan, port: port) else {
        throw MRPError.doNotPropagateAttribute
      }
      _logger
        .debug(
          "MVRP: join indication from port \(port) VID \(vlan.vid) isNew \(isNew) source \(eventSource)"
        )
      // TODO: flush FDB entries following a topology change, if isNew is true
      _dynamicVIDs[port.id, default: []].insert(vlan)
      try await bridge.register(vlan: vlan, on: port)
    }
  }

  // On receipt of a MAD_Leave.indication whose attribute_type is equal to the
  // value of the VID Vector Attribute Type (11.2.3.1.6), the MVRP application
  // element indicates the reception Port as not Registered in the Port Map of
  // the Dynamic VLAN Registration Entry for the VID indicated by the
  // attribute_value parameter. If no such entry exists, the indication is
  // ignored.
  func onLeaveIndication(
    contextIdentifier: MAPContextIdentifier,
    port: P,
    attributeType: AttributeType,
    attributeSubtype: AttributeSubtype?,
    attributeValue: some Value,
    eventSource: EventSource
  ) async throws {
    guard let controller else { throw MRPError.internalError }
    guard let bridge = controller.bridge as? any MVRPAwareBridge<P> else { return }
    guard let attributeType = MVRPAttributeType(rawValue: attributeType)
    else { throw MRPError.unknownAttributeType }
    switch attributeType {
    case .vid:
      let vlan = (attributeValue as! VLAN)
      guard !_isVlanExcluded(vlan, port: port) else {
        throw MRPError.doNotPropagateAttribute
      }
      _logger
        .debug("MVRP: leave indication from port \(port) VID \(vlan.vid) source \(eventSource)")
      _dynamicVIDs[port.id]?.remove(vlan)
      try await bridge.deregister(vlan: vlan, from: port)
    }
  }
}

extension MVRPApplication {
  func onContextAdded(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    // register each port's statically-configured VLANs (8.8.2) and propagate them (10.3 a)
    for port in context {
      _updateStaticVLANs(port: port)
    }
    // 10.3 d): the added ports have not declared attributes that other ports have
    // registered, so re-propagate the other ports' static registrations to them
    for (portID, vlans) in _staticVIDs where !context.contains(where: { $0.id == portID }) {
      guard let controller, let port = try? await controller.port(with: portID)
      else { continue }
      for vlan in vlans {
        try? administrativelyRegister(
          attributeType: MVRPAttributeType.vid.rawValue,
          attributeValue: vlan,
          on: port,
          for: MAPBaseSpanningTreeContext
        )
      }
    }
  }

  func onContextUpdated(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {}

  func onContextRemoved(
    contextIdentifier: MAPContextIdentifier,
    with context: MAPContext<P>
  ) async throws {
    // Participants are torn down (and their attributes flushed) by the context removal; just
    // drop our per-port tracking so a re-added port re-registers from scratch.
    for port in context {
      _staticVIDs[port.id] = nil
      _dynamicVIDs[port.id] = nil
    }
  }

  private func _observeVLANNotifications<B: MVRPAwareBridge>(
    bridge: B,
    controller: MRPController<P>
  ) async throws where B.P == P {
    for try await notification in bridge.vlanRegistrationNotifications {
      guard let port = try? await controller.port(with: notification.portID) else { continue }
      _updateStaticVLANs(port: port)
    }
  }

  // Hold the port's statically-configured VLANs — its tagged VLANs and PVID (11.2.1.3),
  // minus dynamic (peer-registered) entries and operator exclusions — as Registration
  // Fixed (8.8.2, 10.7.2), declaring them out the other ports via MAP; withdraw those no
  // longer statically configured. Runtime additions and removals are both honoured.
  // Idempotent: recomputed from live state, so duplicate notifications are harmless.
  // Internal (not private) so tests can drive it directly.
  func _updateStaticVLANs(port: P) {
    var desired = Set(port.vlans.filter { !_vlanExclusions.contains($0) })
    desired.subtract(port.dynamicVlans) // kernel-flagged (also survives our restart)
    desired.subtract(_dynamicVIDs[port.id] ?? []) // ours this run (flagless-kernel fallback)
    if let pvid = port.pvid, !_vlanExclusions.contains(VLAN(vid: pvid)) {
      desired.insert(VLAN(vid: pvid))
    }
    let current = _staticVIDs[port.id] ?? []
    for vlan in desired.subtracting(current) {
      _logger.debug("MVRP: statically registering VLAN \(vlan.vid) on port \(port)")
      try? administrativelyRegister(
        attributeType: MVRPAttributeType.vid.rawValue,
        attributeValue: vlan,
        on: port,
        for: MAPBaseSpanningTreeContext
      )
    }
    for vlan in current.subtracting(desired) {
      _logger.debug("MVRP: withdrawing static VLAN \(vlan.vid) on port \(port)")
      try? administrativelyDeregister(
        attributeType: MVRPAttributeType.vid.rawValue,
        attributeValue: vlan,
        from: port,
        for: MAPBaseSpanningTreeContext
      )
    }
    _staticVIDs[port.id] = desired.isEmpty ? nil : desired
  }
}

#if RestAPI
extension MVRPApplication: RestApiApplication {
  func registerRestApiHandlers(for httpServer: HTTPServer) async throws {
    let mvrpHandler = MVRPHandler(application: self)

    await httpServer.appendRoute("GET /api/avb/mvrp", to: mvrpHandler)
    await httpServer.appendRoute("GET /api/avb/mvrp/*", to: mvrpHandler)
  }
}
#endif
