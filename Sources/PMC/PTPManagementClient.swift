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
import SystemPackage
#if os(Linux)
import CLinuxSockAddr
import Glibc
import IORing
import IORingUtils
#endif

public actor PTPManagementClient {
  public static let DefaultUDSPath = "/var/run/ptp4l"
  public static let DefaultUDSROPath = "/var/run/ptp4lro"

  // FIXME: using a continuation only allows for one response per request
  private typealias Continuation = CheckedContinuation<PTPManagementRepresentable, Error>

  private var _requests = [UInt16: Continuation]()
  private var _nextSequenceID: UInt16 = 1

  #if os(Linux)
  private let _socket: Socket
  private let _localAddress: sockaddr_un
  private let _peerAddress: sockaddr_un
  private var _rxTask: Task<(), Error>?

  public init(path: String? = nil) async throws {
    let isRoot = geteuid() == 0
    let path = isRoot ? PTPManagementClient.DefaultUDSPath : PTPManagementClient.DefaultUDSROPath
    let prefix = isRoot ? "/var/run" : "/var/tmp"
    _localAddress = try sockaddr_un(
      family: sa_family_t(AF_LOCAL),
      presentationAddress: "\(prefix)/pmc.\(getpid())"
    )
    _peerAddress = try sockaddr_un(family: sa_family_t(AF_LOCAL), presentationAddress: path)
    _socket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_LOCAL), type: SOCK_DGRAM)
    try _socket.bind(to: _localAddress)
    _rxTask = Task { @IORingActor in
      repeat {
        do {
          for try await packet in try await _socket.receiveMessages(count: Int(ETH_DATA_LEN)) {
            try await _rx(packet.buffer)
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
  #else
  private func _tx(_ buffer: [UInt8]) async throws {
    throw PTP.Error.notImplemented
  }
  #endif

  private func _rx(_ buffer: [UInt8]) async throws {
    do {
      var deserializationContext = DeserializationContext(buffer)
      let tlv = try PTP.ManagementMessage(deserializationContext: &deserializationContext)
      _resume(sequenceId: tlv.header.sequenceId, with: .success(tlv))
    } catch {
      // FIXME: avoid decoding Header twice
      var deserializationContext = DeserializationContext(buffer)
      let header = try PTP.Header(deserializationContext: &deserializationContext)
      _resume(sequenceId: header.sequenceId, with: .failure(error))
    }
  }

  private func _allocateSequenceId() -> UInt16 {
    defer { _nextSequenceID &+= 1 }
    if _nextSequenceID == 0 { _nextSequenceID = 1 }
    return _nextSequenceID
  }

  private func _resume(sequenceId: UInt16, with result: Result<PTP.ManagementMessage, Error>) {
    let result: Result<PTPManagementRepresentable, Error> = result.flatMap { result in
      Result(catching: {
        guard result.actionField == .response || result.actionField == .acknowledge else {
          throw PTP.Error.invalidManagementActionField
        }
        return try result.managementTLV.data
      })
    }

    if let continuation = _requests[sequenceId] {
      continuation.resume(with: result)
      _requests[sequenceId] = nil
    }
  }

  private func _request(
    _ request: PTP.ManagementMessage
  ) async throws -> PTPManagementRepresentable {
    let sequenceId = request.header.sequenceId

    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        _requests[sequenceId] = continuation
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

  private func _request<T: PTPManagementRepresentable>(
    domainNumber: UInt8 = 0,
    sourcePortIdentity: PTP.PortIdentity? = nil,
    targetPortIdentity: PTP.PortIdentity? = nil,
    action actionField: PTP.ActionField,
    managementTLV: PTPManagementTLV
  ) async throws -> T {
    let header = PTP.Header(
      messageType: .Management,
      messageLength: UInt16(PTP.ManagementMessage.Size + managementTLV.size),
      domainNumber: domainNumber,
      sourcePortIdentity: sourcePortIdentity ?? PTP.PortIdentity(),
      sequenceId: _allocateSequenceId()
    )
    let request = PTP.ManagementMessage(
      header: header,
      targetPortIdentity: targetPortIdentity ?? PTP.PortIdentity(),
      startingBoundaryHops: 0,
      boundaryHops: 0,
      actionField: actionField,
      managementTLV: managementTLV
    )
    return try await withThrowingTimeout(of: .seconds(0.1)) {
      guard let response = try await self._request(request) as? T else {
        throw PTP.Error.responseMessageTypeMismatch
      }
      return response
    }
  }

  private func _request<T: PTPManagementRepresentable>(
    domainNumber: UInt8 = 0,
    sourcePortIdentity: PTP.PortIdentity? = nil,
    targetPortIdentity: PTP.PortIdentity? = nil,
    action: PTP.ActionField,
    managementId: PTPManagementID
  ) async throws -> T {
    let managementTLV = PTPManagementTLV(managementId: managementId)
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
      action: .get,
      managementId: .NULL_PTP_MANAGEMENT
    )
  }

  public func getDefaultDataSet(
    domainNumber: UInt8 = 0
  ) async throws -> DefaultDataSet {
    try await _request(
      domainNumber: domainNumber,
      action: .get,
      managementId: .DEFAULT_DATA_SET
    )
  }

  public func getPortDataSet(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortDataSet {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get,
      managementId: .PORT_DATA_SET
    )
  }

  public func getTime(
    domainNumber: UInt8 = 0
  ) async throws -> Time {
    try await _request(domainNumber: domainNumber, action: .get, managementId: .TIME)
  }

  public func getClockAccuracy(
    domainNumber: UInt8 = 0
  ) async throws -> ClockAccuracy {
    try await _request(domainNumber: domainNumber, action: .get, managementId: .CLOCK_ACCURACY)
  }

  public func getPriority1(
    domainNumber: UInt8 = 0
  ) async throws -> Priority1 {
    try await _request(domainNumber: domainNumber, action: .get, managementId: .PRIORITY1)
  }

  public func getPriority2(
    domainNumber: UInt8 = 0
  ) async throws -> Priority2 {
    try await _request(domainNumber: domainNumber, action: .get, managementId: .PRIORITY2)
  }

  public func getPortDataSetNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortDataSetNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get,
      managementId: .PORT_DATA_SET_NP
    )
  }

  public func getPortPropertiesNP(
    domainNumber: UInt8 = 0,
    portNumber: UInt16
  ) async throws -> PortPropertiesNP {
    try await _request(
      domainNumber: domainNumber,
      targetPortIdentity: PTP.PortIdentity(portNumber: portNumber),
      action: .get,
      managementId: .PORT_PROPERTIES_NP
    )
  }
}
