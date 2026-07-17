//
// Copyright (c) 2026 PADL Software Pty Ltd
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

// A native, non-blocking Swift client for the excelfore gptp2d IPC socket, built on
// IORing. The wire protocol — an AF_UNIX SOCK_DGRAM socket at /tmp/gptp2d_ipc, the
// packed 44-byte gptpipc_client_req_data_t request and 1473-byte gptpipc_gptpd_data_t
// response — is transcribed from the gptpipc.h layout; no excelfore (GPL) source is
// compiled or linked. The structures are packed and native-endian with no version
// field, so the sizes below are the compatibility contract with the daemon.

#if os(Linux)
import Glibc
import IORing
import IORingUtils
import SocketAddress
#endif

// gptpipc_gport_data_t, restricted to the 802.1AS per-port state we consume.
public struct GPTP2dPortInfo: Sendable {
  public let portIndex: Int32
  public let asCapable: Bool
  public let portOper: Bool
  // neighborPropDelay (meanLinkDelay) in nanoseconds, 0 until the first pdelay exchange.
  public let neighborPropDelayNs: UInt64
  public let neighborRateRatio: Double
}

public enum GPTP2dError: Error {
  // The gptp2d IPC client is only available on Linux (thrown by the non-Linux stub).
  case unsupported
  // gptp2d did not answer within the deadline, or does not know the port.
  case timedOut
  // No gptp2d port is configured for this network interface.
  case unknownInterface
}

public actor GPTP2dClient {
  public static let DefaultPath = "/tmp/gptp2d_ipc"

  // gptp_ipc_command_t
  private static let cmdReqNdportInfo: UInt32 = 1
  private static let cmdReqGportInfo: UInt32 = 2
  // gptpd_data_type_t
  private static let dtypeNdportd: UInt32 = 1
  private static let dtypeGportd: UInt32 = 2

  private static let requestSize = 44 // sizeof(gptpipc_client_req_data_t)
  private static let responseSize = 1473 // sizeof(gptpipc_gptpd_data_t)
  // gptpipc_client_req_data_t field offsets
  private static let reqCmd = 0, reqDomainNumber = 4, reqDomainIndex = 8, reqPortIndex = 12
  // gptpipc_gptpd_data_t field offsets (dtype, then the union at 4)
  private static let respDtype = 0
  // gptpipc_gport_data_t, relative to the union
  private static let gportPortIndex = 8, gportAsCapable = 20, gportPortOper = 21
  private static let gportPDelay = 24, gportPDelayRateRatio = 32
  // gptpipc_data_netlink_t, relative to the union
  private static let ndportDevname = 21, ndportDevnameSize = 16

  // gptp2d answers a well-formed request promptly or not at all: an unconfigured port index
  // draws no reply, which is how port enumeration finds its upper bound.
  private static let requestTimeout = Duration.milliseconds(100)

  #if os(Linux)
  private let _socket: Socket
  private let _localPath: String
  private var _portIndices = [String: Int32]()

  // Connect to gptp2d; throws if it is not running / not reachable.
  public init(path: String? = nil) async throws {
    let path = path ?? Self.DefaultPath
    // gptp2d addresses its reply to our bound name, so it must be our own filesystem node
    // (unlike mstpd, the excelfore IPC socket is not abstract).
    _localPath = "\(path).\(getpid())"
    unlink(_localPath)
    _socket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_LOCAL), type: SOCK_DGRAM)
    try _socket.bind(to: sockaddr_un(
      family: sa_family_t(AF_LOCAL),
      presentationAddress: _localPath
    ))
    // Connecting also filters out datagrams from anything other than gptp2d.
    try await _socket.connect(to: sockaddr_un(
      family: sa_family_t(AF_LOCAL),
      presentationAddress: path
    ))
  }

  deinit { unlink(_localPath) }

  // 802.1AS state for the gptp2d port serving this interface, in the given gPTP domain.
  public func portInfo(interface: String, domainNumber: Int32 = 0) async throws -> GPTP2dPortInfo {
    let portIndex = try await _portIndex(for: interface)
    try await _send(cmd: Self.cmdReqGportInfo, domainNumber: domainNumber, portIndex: portIndex)
    let reply = try await _receive(dtype: Self.dtypeGportd, portIndex: portIndex)
    return GPTP2dPortInfo(
      portIndex: portIndex,
      asCapable: reply[Self.gportAsCapable] != 0,
      portOper: reply[Self.gportPortOper] != 0,
      neighborPropDelayNs: reply._load(UInt64.self, at: Self.gportPDelay),
      neighborRateRatio: reply._load(Double.self, at: Self.gportPDelayRateRatio)
    )
  }

  // Port indices are contiguous from 1, and the NDPORT reply names the device but does not
  // carry its index, so probe indices in turn and stop at the first that does not answer.
  private func _portIndex(for interface: String) async throws -> Int32 {
    if let portIndex = _portIndices[interface] { return portIndex }
    _portIndices.removeAll()
    var portIndex: Int32 = 1
    while true {
      try await _send(cmd: Self.cmdReqNdportInfo, portIndex: portIndex)
      guard let reply = try? await _receive(dtype: Self.dtypeNdportd) else { break }
      _portIndices[Self._devname(reply)] = portIndex
      portIndex += 1
    }
    guard let portIndex = _portIndices[interface] else { throw GPTP2dError.unknownInterface }
    return portIndex
  }

  private func _send(cmd: UInt32, domainNumber: Int32 = 0, portIndex: Int32) async throws {
    var request = [UInt8](repeating: 0, count: Self.requestSize)
    request.withUnsafeMutableBytes {
      $0.storeBytes(of: cmd, toByteOffset: Self.reqCmd, as: UInt32.self)
      $0.storeBytes(of: domainNumber, toByteOffset: Self.reqDomainNumber, as: Int32.self)
      // domainIndex -1 tells gptp2d to select the domain by number instead.
      $0.storeBytes(of: Int32(-1), toByteOffset: Self.reqDomainIndex, as: Int32.self)
      $0.storeBytes(of: portIndex, toByteOffset: Self.reqPortIndex, as: Int32.self)
    }
    try await _socket.send(request)
  }

  // gptp2d pushes unsolicited notices (asCapable, netdev and GM changes) onto the same socket,
  // so read until the datagram we asked for arrives, discarding anything else.
  private func _receive(dtype: UInt32, portIndex: Int32? = nil) async throws -> [UInt8] {
    let socket = _socket // Sendable; the actor's serial calls mean no concurrent socket use
    return try await _withTimeout(Self.requestTimeout) {
      while true {
        let reply: [UInt8] = try await socket.receive(count: Self.responseSize)
        guard reply.count == Self.responseSize,
              reply._load(UInt32.self, at: Self.respDtype) == dtype else { continue }
        guard let portIndex else { return reply }
        if reply._load(Int32.self, at: Self.gportPortIndex) == portIndex { return reply }
      }
    }
  }

  private static func _devname(_ reply: [UInt8]) -> String {
    let devname = reply[ndportDevname..<(ndportDevname + ndportDevnameSize)].prefix { $0 != 0 }
    return String(decoding: devname, as: UTF8.self)
  }
  #else
  public init(path: String? = nil) async throws { throw GPTP2dError.unsupported }

  public func portInfo(interface: String, domainNumber: Int32 = 0) async throws -> GPTP2dPortInfo {
    throw GPTP2dError.unsupported
  }
  #endif
}

private extension [UInt8] {
  func _load<T>(_ type: T.Type, at offset: Int) -> T {
    withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
  }
}

// Run an async operation with a deadline; throws GPTP2dError.timedOut (cancelling the operation)
// if it does not finish in time, so a wedged daemon can't stall the caller.
private func _withTimeout<R: Sendable>(
  _ duration: Duration,
  _ operation: @escaping @Sendable () async throws -> R
) async throws -> R {
  try await withThrowingTaskGroup(of: R.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw GPTP2dError.timedOut
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
