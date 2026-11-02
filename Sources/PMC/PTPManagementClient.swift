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

import IEEE802
import Synchronization
import SystemPackage
#if os(Linux)
import CLinuxSockAddr
import Glibc
import IORing
import IORingUtils
#elseif canImport(Darwin)
import Darwin
#endif

public actor PTPManagementClient {
  public static let DefaultUDSPath = "/var/run/ptp/ptp4l"
  public static let DefaultUDSROPath = "/var/run/ptp/ptp4lro"

  // FIXME: using a continuation only allows for one response per request
  private typealias Continuation = CheckedContinuation<PTPManagementRepresentable, Error>

  private struct Request {
    let managementId: PTPManagementID
    let continuation: Continuation
  }

  private var _requests = [UInt16: Request]()
  private var _nextSequenceID: UInt16 = 1

  // ptp4l keys event subscriptions on the source port identity, so it must be unique per
  // client; linuxptp's own pmc derives it from the process ID in the same way. Each event
  // subscriber (see events()) is a further client, told apart by its index.
  private nonisolated static func _makeSourcePortIdentity(subscriber: UInt8) -> PTP.PortIdentity {
    let pid = UInt32(bitPattern: getpid())
    return PTP.PortIdentity(
      clockIdentity: PTP.ClockIdentity(id: (
        0, 0, 0, 0, 0, subscriber,
        UInt8(truncatingIfNeeded: pid >> 24),
        UInt8(truncatingIfNeeded: pid >> 16)
      )),
      portNumber: UInt16(truncatingIfNeeded: pid)
    )
  }

  private var _sourcePortIdentity = PTPManagementClient._makeSourcePortIdentity(subscriber: 0)

  // an event subscriber's stream; nil on a request client, which ptp4l never notifies
  private var _eventContinuation: AsyncThrowingStream<PTPManagementEvent, Error>.Continuation?

  // a subscriber that falls behind keeps the newest events: each carries a whole data set,
  // so a newer one supersedes an older one for the same port or clock
  public static let EventBufferDepth = 256
  public static let DefaultSubscriptionDuration: UInt16 = 30

  #if os(Linux)
  private let _socket: Socket
  private let _path: String
  private let _localPath: String
  private let _peerAddress: sockaddr_un
  private var _rxTask: Task<(), Error>?

  private static let _nextSubscriber = Mutex<UInt8>(0)

  public init(path: String? = nil) async throws {
    try await self.init(path: path, subscriber: 0, events: nil)
  }

  private init(
    path: String?,
    subscriber: UInt8,
    events: AsyncThrowingStream<PTPManagementEvent, Error>.Continuation?
  ) async throws {
    let isRoot = geteuid() == 0
    // ptp4l serves the read-write socket to root only; unprivileged clients get the RO one.
    let defaultPath = isRoot ? Self.DefaultUDSPath : Self.DefaultUDSROPath
    let path = path ?? defaultPath
    let prefix = isRoot ? "/var/run" : "/var/tmp"
    let suffix = subscriber == 0 ? "" : ".events\(subscriber)"
    _path = path
    _localPath = "\(prefix)/pmc.\(getpid())\(suffix)"
    _sourcePortIdentity = Self._makeSourcePortIdentity(subscriber: subscriber)
    _eventContinuation = events
    let localAddress = try sockaddr_un(
      family: sa_family_t(AF_LOCAL),
      presentationAddress: _localPath
    )
    _peerAddress = try sockaddr_un(family: sa_family_t(AF_LOCAL), presentationAddress: path)
    _socket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_LOCAL), type: SOCK_DGRAM)
    // a socket file left by an earlier process with our PID would fail the bind; only a
    // subscriber's, since that is the one a kill leaves behind while ptp4l still sends to it
    if subscriber != 0 {
      unlink(_localPath)
    }
    try _socket.bind(to: localAddress)
    _rxTask = Task {
      repeat {
        do {
          for try await packet in try await _socket.receiveMessages(count: Int(ETH_DATA_LEN)) {
            await _rx(packet.buffer)
          }
        } catch Errno.interrupted {} // restart on interrupted system call
      } while !Task.isCancelled
    }
  }

  private func _tx(_ buffer: [UInt8]) async throws {
    var _peerAddress = _peerAddress
    let _peerAddressBuffer = withUnsafeBytes(of: &_peerAddress) { Array($0) }
    try await _socket.sendMessage(.init(name: _peerAddressBuffer, buffer: buffer))
  }

  deinit {
    _rxTask?.cancel()
  }

  // ends the receive task, whose capture of self is what keeps this client alive, so the
  // socket closes once the last request returns; the socket file goes now
  private func _shutdown() {
    _rxTask?.cancel()
    _rxTask = nil
    unlink(_localPath)
    _eventContinuation?.finish()
    _eventContinuation = nil
  }
  #else
  private func _tx(_ buffer: [UInt8]) async throws {
    throw PTP.Error.notImplemented
  }
  #endif

  // a datagram that cannot be attributed to a request is dropped: throwing here would
  // tear down the receive task and silently deafen the client for its remaining lifetime
  private func _rx(_ buffer: [UInt8]) async {
    do {
      let tlv = try buffer.withParserSpan { input in
        try PTP.ManagementMessage(parsing: &input)
      }
      if !_resume(sequenceId: tlv.header.sequenceId, with: .success(tlv)) {
        _notify(tlv)
      }
    } catch {
      // a rejected request throws its PTPManagementError out of the TLV parse; any other
      // parse failure cannot be attributed (it may be a notification sharing a sequence ID)
      // FIXME: avoid decoding Header twice
      guard error is PTPManagementError, let header = try? buffer.withParserSpan({ input in
        try PTP.Header(parsing: &input)
      }) else {
        return
      }
      _resume(sequenceId: header.sequenceId, with: .failure(error))
    }
  }

  private func _allocateSequenceId() -> UInt16 {
    defer { _nextSequenceID &+= 1 }
    if _nextSequenceID == 0 {
      _nextSequenceID = 1
    }
    return _nextSequenceID
  }

  // a subscriber's only requests are for SUBSCRIBE_EVENTS_NP, which ptp4l never pushes, so
  // whatever it cannot match to a request is a notification
  private func _notify(_ message: PTP.ManagementMessage) {
    guard let _eventContinuation,
          let event = try? PTPManagementEvent(notification: message) else { return }
    _eventContinuation.yield(event)
  }

  // returns whether the message answered a pending request
  @discardableResult
  private func _resume(
    sequenceId: UInt16,
    with result: Result<PTP.ManagementMessage, Error>
  ) -> Bool {
    guard let request = _requests[sequenceId] else { return false }

    // an unsolicited response carries a sequence ID from ptp4l's own counter, so a
    // matching ID alone does not identify our reply
    if case let .success(message) = result,
       message.managementTLV.managementId != request.managementId
    {
      return false
    }

    let result: Result<PTPManagementRepresentable, Error> = result.flatMap { result in
      Result(catching: {
        guard result.actionField == .response || result.actionField == .acknowledge else {
          throw PTP.Error.invalidManagementActionField
        }
        return try result.managementTLV.data
      })
    }

    request.continuation.resume(with: result)
    _requests[sequenceId] = nil
    return true
  }

  private func _request(
    _ request: PTP.ManagementMessage
  ) async throws -> PTPManagementRepresentable {
    let sequenceId = request.header.sequenceId

    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        _requests[sequenceId] = Request(
          managementId: request.managementTLV.managementId,
          continuation: continuation
        )
        Task {
          do {
            try await _tx(request.serialized())
          } catch {
            _resume(sequenceId: request.header.sequenceId, with: .failure(error))
          }
        }
      }
    }, onCancel: {
      Task { await _resume(sequenceId: sequenceId, with: .failure(CancellationError())) }
    })
  }

  static func _makeRequest(
    domainNumber: UInt8,
    sourcePortIdentity: PTP.PortIdentity,
    targetPortIdentity: PTP.PortIdentity,
    sequenceId: UInt16,
    action actionField: PTP.ActionField,
    managementTLV: PTPManagementTLV
  ) -> PTP.ManagementMessage {
    let header = PTP.Header(
      messageType: .Management,
      messageLength: UInt16(PTP.ManagementMessage.Size + managementTLV.size),
      domainNumber: domainNumber,
      sourcePortIdentity: sourcePortIdentity,
      sequenceId: sequenceId
    )
    return PTP.ManagementMessage(
      header: header,
      targetPortIdentity: targetPortIdentity,
      startingBoundaryHops: 0,
      boundaryHops: 0,
      actionField: actionField,
      managementTLV: managementTLV
    )
  }

  private func _request<T: PTPManagementRepresentable>(
    domainNumber: UInt8 = 0,
    sourcePortIdentity: PTP.PortIdentity? = nil,
    targetPortIdentity: PTP.PortIdentity? = nil,
    action actionField: PTP.ActionField,
    managementTLV: PTPManagementTLV
  ) async throws -> T {
    let request = Self._makeRequest(
      domainNumber: domainNumber,
      sourcePortIdentity: sourcePortIdentity ?? _sourcePortIdentity,
      targetPortIdentity: targetPortIdentity ?? PTP.PortIdentity(),
      sequenceId: _allocateSequenceId(),
      action: actionField,
      managementTLV: managementTLV
    )
    return try await withThrowingTimeout(of: .seconds(0.1)) {
      guard let response = try await self._request(request) as? T else {
        throw PTP.Error.responseMessageTypeMismatch
      }
      return response
    }
  }

  // for GET and COMMAND requests without associated data: the management ID is the one
  // declared by the expected response type
  private func _request<T: PTPManagementRepresentable>(
    domainNumber: UInt8 = 0,
    sourcePortIdentity: PTP.PortIdentity? = nil,
    targetPortIdentity: PTP.PortIdentity? = nil,
    action: PTP.ActionField
  ) async throws -> T {
    let managementTLV = PTPManagementTLV(managementId: T.managementId)
    return try await _request(
      domainNumber: domainNumber,
      sourcePortIdentity: sourcePortIdentity,
      targetPortIdentity: targetPortIdentity,
      action: action,
      managementTLV: managementTLV
    )
  }

  private func _request<T: PTPManagementRepresentable>(
    domainNumber: UInt8 = 0,
    sourcePortIdentity: PTP.PortIdentity? = nil,
    targetPortIdentity: PTP.PortIdentity? = nil,
    action: PTP.ActionField,
    _ request: PTPManagementRepresentable
  ) async throws -> T {
    let managementTLV = try PTPManagementTLV(request)
    return try await _request(
      domainNumber: domainNumber,
      sourcePortIdentity: sourcePortIdentity,
      targetPortIdentity: targetPortIdentity,
      action: action,
      managementTLV: managementTLV
    )
  }

  public func getNullPtpManagement(
    domainNumber: UInt8 = 0
  ) async throws {
    let _: Null = try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func getDefaultDataSet(
    domainNumber: UInt8 = 0
  ) async throws -> DefaultDataSet {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func getPortDataSet(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortDataSet {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getTime(
    domainNumber: UInt8 = 0
  ) async throws -> Time {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getClockAccuracy(
    domainNumber: UInt8 = 0
  ) async throws -> ClockAccuracy {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getPriority1(
    domainNumber: UInt8 = 0
  ) async throws -> Priority1 {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getPriority2(
    domainNumber: UInt8 = 0
  ) async throws -> Priority2 {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getPortDataSetNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortDataSetNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getPortPropertiesNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortPropertiesNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  // MARK: - clock data sets

  public func getClockDescription(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> ClockDescription {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getUserDescription(
    domainNumber: UInt8 = 0
  ) async throws -> UserDescription {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getCurrentDataSet(
    domainNumber: UInt8 = 0
  ) async throws -> CurrentDataSet {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getParentDataSet(
    domainNumber: UInt8 = 0
  ) async throws -> ParentDataSet {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getTimePropertiesDataSet(
    domainNumber: UInt8 = 0
  ) async throws -> TimePropertiesDataSet {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func getDomain(
    domainNumber: UInt8 = 0
  ) async throws -> Domain {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getSlaveOnly(
    domainNumber: UInt8 = 0
  ) async throws -> SlaveOnly {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getTraceabilityProperties(
    domainNumber: UInt8 = 0
  ) async throws -> TraceabilityProperties {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func getTimescaleProperties(
    domainNumber: UInt8 = 0
  ) async throws -> TimescaleProperties {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func setPriority1(
    _ priority1: UInt8,
    domainNumber: UInt8 = 0
  ) async throws -> Priority1 {
    try await _request(domainNumber: domainNumber, action: .set, Priority1(priority1: priority1))
  }

  public func setPriority2(
    _ priority2: UInt8,
    domainNumber: UInt8 = 0
  ) async throws -> Priority2 {
    try await _request(domainNumber: domainNumber, action: .set, Priority2(priority2: priority2))
  }

  // MARK: - alternate time offsets

  // unlike every other GET these carry a data field: the key field selects one of the
  // configured time zones, so it has to travel with the request

  public func getAlternateTimeOffsetEnable(
    domainNumber: UInt8 = 0,
    keyField: UInt8
  ) async throws -> AlternateTimeOffsetEnable {
    try await _request(
      domainNumber: domainNumber,
      action: .get,
      AlternateTimeOffsetEnable(keyField: keyField, enabled: false)
    )
  }

  public func setAlternateTimeOffsetEnable(
    domainNumber: UInt8 = 0,
    keyField: UInt8,
    enabled: Bool
  ) async throws -> AlternateTimeOffsetEnable {
    try await _request(
      domainNumber: domainNumber,
      action: .set,
      AlternateTimeOffsetEnable(keyField: keyField, enabled: enabled)
    )
  }

  public func getAlternateTimeOffsetName(
    domainNumber: UInt8 = 0,
    keyField: UInt8
  ) async throws -> AlternateTimeOffsetName {
    try await _request(
      domainNumber: domainNumber,
      action: .get,
      AlternateTimeOffsetName(keyField: keyField, displayName: PTP.PTPText(""))
    )
  }

  public func setAlternateTimeOffsetName(
    domainNumber: UInt8 = 0,
    keyField: UInt8,
    displayName: String
  ) async throws -> AlternateTimeOffsetName {
    try await _request(
      domainNumber: domainNumber,
      action: .set,
      AlternateTimeOffsetName(keyField: keyField, displayName: PTP.PTPText(displayName))
    )
  }

  public func getAlternateTimeOffsetMaxKey(
    domainNumber: UInt8 = 0
  ) async throws -> AlternateTimeOffsetMaxKey {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func getAlternateTimeOffsetProperties(
    domainNumber: UInt8 = 0,
    keyField: UInt8
  ) async throws -> AlternateTimeOffsetProperties {
    try await _request(
      domainNumber: domainNumber,
      action: .get,
      AlternateTimeOffsetProperties(
        keyField: keyField,
        currentOffset: 0,
        jumpSeconds: 0,
        timeOfNextJump: 0
      )
    )
  }

  public func setAlternateTimeOffsetProperties(
    domainNumber: UInt8 = 0,
    keyField: UInt8,
    currentOffset: Int32,
    jumpSeconds: Int32,
    timeOfNextJump: UInt64
  ) async throws -> AlternateTimeOffsetProperties {
    try await _request(
      domainNumber: domainNumber,
      action: .set,
      AlternateTimeOffsetProperties(
        keyField: keyField,
        currentOffset: currentOffset,
        jumpSeconds: jumpSeconds,
        timeOfNextJump: timeOfNextJump
      )
    )
  }

  // MARK: - port data sets

  public func getLogAnnounceInterval(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> LogAnnounceInterval {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getAnnounceReceiptTimeout(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> AnnounceReceiptTimeout {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getLogSyncInterval(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> LogSyncInterval {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getVersionNumber(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> VersionNumber {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getMasterOnly(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> MasterOnly {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getDelayMechanism(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> DelayMechanism {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getLogMinPdelayReqInterval(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> LogMinPdelayReqInterval {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func enablePort(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws {
    let _: EnablePort = try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .command
    )
  }

  public func disablePort(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws {
    let _: DisablePort = try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .command
    )
  }

  // MARK: - linuxptp specific clock management

  public func getTimeStatusNP(
    domainNumber: UInt8 = 0
  ) async throws -> TimeStatusNP {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  public func getGrandmasterSettingsNP(
    domainNumber: UInt8 = 0
  ) async throws -> GrandmasterSettingsNP {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func setGrandmasterSettingsNP(
    domainNumber: UInt8 = 0,
    clockQuality: PTP.ClockQuality,
    currentUtcOffset: Int16,
    timeFlags: TimePropertiesDataSet.Flags,
    timeSource: PTP.TimeSource
  ) async throws -> GrandmasterSettingsNP {
    try await _request(
      domainNumber: domainNumber,
      action: .set,
      GrandmasterSettingsNP(
        clockQuality: clockQuality,
        currentUtcOffset: currentUtcOffset,
        timeFlags: timeFlags,
        timeSource: timeSource
      )
    )
  }

  public func getSubscribeEventsNP(
    domainNumber: UInt8 = 0
  ) async throws -> SubscribeEventsNP {
    try await _request(domainNumber: domainNumber, action: .get)
  }

  // ptp4l sends the events to whichever socket last SET the subscription for this source port
  // identity, so events() subscribes from a client of its own rather than through this one
  func setSubscribeEventsNP(
    _ subscription: SubscribeEventsNP,
    domainNumber: UInt8 = 0
  ) async throws -> SubscribeEventsNP {
    try await _request(domainNumber: domainNumber, action: .set, subscription)
  }

  public func getSynchronizationUncertainNP(
    domainNumber: UInt8 = 0
  ) async throws -> SynchronizationUncertainNP {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func setSynchronizationUncertainNP(
    _ uncertain: SynchronizationUncertainNP.Uncertain,
    domainNumber: UInt8 = 0
  ) async throws -> SynchronizationUncertainNP {
    try await _request(
      domainNumber: domainNumber,
      action: .set,
      SynchronizationUncertainNP(uncertain: uncertain)
    )
  }

  public func getExternalGrandmasterPropertiesNP(
    domainNumber: UInt8 = 0
  ) async throws -> ExternalGrandmasterPropertiesNP {
    try await _request(
      domainNumber: domainNumber,
      action: .get
    )
  }

  public func setExternalGrandmasterPropertiesNP(
    domainNumber: UInt8 = 0,
    gmIdentity: PTP.ClockIdentity,
    stepsRemoved: UInt16
  ) async throws -> ExternalGrandmasterPropertiesNP {
    try await _request(
      domainNumber: domainNumber,
      action: .set,
      ExternalGrandmasterPropertiesNP(gmIdentity: gmIdentity, stepsRemoved: stepsRemoved)
    )
  }

  // MARK: - linuxptp specific port management

  public func setPortDataSetNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16,
    neighborPropDelayThresh: UInt32
  ) async throws -> PortDataSetNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .set,
      PortDataSetNP(neighborPropDelayThresh: neighborPropDelayThresh, asCapable: 0)
    )
  }

  public func getPortStatsNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortStatsNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getPortServiceStatsNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortServiceStatsNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getUnicastMasterTableNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> UnicastMasterTableNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getPortHwclockNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortHwclockNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getPowerProfileSettingsNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PowerProfileSettingsNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func setPowerProfileSettingsNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16,
    version: PowerProfileSettingsNP.Version,
    grandmasterID: UInt16,
    grandmasterTimeInaccuracy: UInt32,
    networkTimeInaccuracy: UInt32,
    totalTimeInaccuracy: UInt32
  ) async throws -> PowerProfileSettingsNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .set,
      PowerProfileSettingsNP(
        version: version,
        grandmasterID: grandmasterID,
        grandmasterTimeInaccuracy: grandmasterTimeInaccuracy,
        networkTimeInaccuracy: networkTimeInaccuracy,
        totalTimeInaccuracy: totalTimeInaccuracy
      )
    )
  }

  public func getCmldsInfoNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> CmldsInfoNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func getPortCorrectionsNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortCorrectionsNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get
    )
  }

  public func setPortCorrectionsNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16,
    egressLatency: Int64,
    ingressLatency: Int64,
    delayAsymmetry: Int64
  ) async throws -> PortCorrectionsNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .set,
      PortCorrectionsNP(
        egressLatency: egressLatency,
        ingressLatency: ingressLatency,
        delayAsymmetry: delayAsymmetry
      )
    )
  }
}

// MARK: - event subscription (SUBSCRIBE_EVENTS_NP)

public extension PTPManagementClient {
  // Subscribes to ptp4l's push notifications and returns them as a stream that starts with
  // .subscribed once ptp4l holds the subscription. The subscription is renewed three times per
  // `duration` seconds, each renewal doubling as a keepalive: a ptp4l that stops answering
  // yields .unsubscribed, and one that restarted yields .subscribed again once re-subscribed.
  // While ptp4l is unreachable the renewal is retried every second.
  //
  // The stream throws only if ptp4l refuses the subscription (a PTPManagementError, e.g. on
  // the read-only socket, which ptp4l does not let subscribe). Ending iteration unsubscribes.
  nonisolated func events(
    _ events: Set<SubscribeEventsNP.Event> = Set(SubscribeEventsNP.Event.allCases),
    duration: UInt16 = PTPManagementClient.DefaultSubscriptionDuration,
    domainNumber: UInt8 = 0
  ) -> AsyncThrowingStream<PTPManagementEvent, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: PTPManagementEvent.self,
      bufferingPolicy: .bufferingNewest(Self.EventBufferDepth)
    )
    #if os(Linux)
    let path = _path
    let task = Task {
      let subscriber: PTPManagementClient
      do {
        subscriber = try await PTPManagementClient(
          path: path,
          subscriber: Self._allocateSubscriber(),
          events: continuation
        )
      } catch {
        continuation.finish(throwing: error)
        return
      }
      await subscriber._keepSubscribed(
        SubscribeEventsNP(duration: duration, events: events),
        domainNumber: domainNumber
      )
    }
    continuation.onTermination = { _ in task.cancel() }
    #else
    continuation.finish(throwing: PTP.Error.notImplemented)
    #endif
    return stream
  }
}

#if os(Linux)
private extension PTPManagementClient {
  // 1...255: index 0 is every request client's identity
  static func _allocateSubscriber() -> UInt8 {
    _nextSubscriber.withLock { index in
      index = index == UInt8.max ? 1 : index + 1
      return index
    }
  }

  // runs until the stream's consumer goes away (cancelling us) or ptp4l refuses
  func _keepSubscribed(_ subscription: SubscribeEventsNP, domainNumber: UInt8) async {
    var state = PTPEventSubscriptionState(duration: subscription.duration)
    let subscription = SubscribeEventsNP(
      duration: state.duration,
      events: Set(subscription.events)
    )

    while !Task.isCancelled {
      let step: PTPEventSubscriptionState.Step
      do {
        let wasHeld = try await state.needsProbe
          ? getSubscribeEventsNP(domainNumber: domainNumber).holds(subscription)
          : false
        _ = try await setSubscribeEventsNP(subscription, domainNumber: domainNumber)
        step = state.renewed(wasHeld: wasHeld)
      } catch is CancellationError {
        break
      } catch let error as PTPManagementError {
        _eventContinuation?.finish(throwing: error)
        break
      } catch {
        step = state.failed()
      }
      switch step.transition {
      case .subscribed: _eventContinuation?.yield(.subscribed)
      case .unsubscribed: _eventContinuation?.yield(.unsubscribed)
      case nil: break
      }
      do {
        try await Task.sleep(for: step.delay)
      } catch {
        break
      }
    }

    // this task is cancelled, which would fail the request at once; an unstructured task is not
    Task {
      _ = try? await setSubscribeEventsNP(
        SubscribeEventsNP(duration: 0, events: []),
        domainNumber: domainNumber
      )
      _shutdown()
    }
  }
}
#endif
