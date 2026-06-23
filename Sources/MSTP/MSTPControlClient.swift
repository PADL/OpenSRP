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

// A native, non-blocking Swift client for the mstpd control socket, built on
// IORing. The wire protocol — an abstract AF_UNIX SOCK_DGRAM socket named
// "\0.mstp_server", the 5x int32 ctl_msg_hdr framing, the get_cist_port_status
// command (105), and the CIST_PortStatus field offsets — is reverse-engineered
// from the mstpd headers; no mstpd (GPL) source is compiled or linked. Calls are
// best-effort: cistPortStatus soft-fails to nil if mstpd is absent or the reply
// is malformed, and init throws if mstpd cannot be reached.

#if os(Linux)
import Glibc
import IORing
import IORingUtils
#endif

public enum MSTPPortRole: Int32, Sendable, CustomStringConvertible {
  case disabled = 0, root = 1, designated = 2, alternate = 3, backup = 4, master = 5
  public var description: String {
    switch self {
    case .disabled: "Disabled"
    case .root: "Root"
    case .designated: "Designated"
    case .alternate: "Alternate"
    case .backup: "Backup"
    case .master: "Master"
    }
  }
}

// BR_STATE_xxx, as carried in CIST_PortStatus.state
public enum MSTPPortState: Int32, Sendable, CustomStringConvertible {
  case disabled = 0, listening = 1, learning = 2, forwarding = 3, blocking = 4
  public var description: String {
    switch self {
    case .disabled: "disabled"
    case .listening: "listening"
    case .learning: "learning"
    case .forwarding: "forwarding"
    case .blocking: "blocking"
    }
  }
}

public struct MSTPCISTPortStatus: Sendable {
  public let role: MSTPPortRole
  public let state: MSTPPortState
}

public actor MSTPControlClient {
  // mstpd ctl_functions.h
  private static let serverName = ".mstp_server"
  private static let cmdGetCISTPortStatus: Int32 = 105
  private static let headerSize = 5 * MemoryLayout<Int32>.size // cmd, lin, lout, llog, res
  private static let resOffset = 16 // ctl_msg_hdr.res
  private static let cistPortStatusSize = 136 // sizeof(CIST_PortStatus)
  private static let logBufferSize = 256 // LOG_STRING_LEN
  // field offsets within CIST_PortStatus (arch-independent: no pointers)
  private static let stateOffset = 4
  private static let roleOffset = 64

  #if os(Linux)
  private let _socket: Socket

  // Connect to mstpd; throws if it is not running / not reachable.
  public init() async throws {
    _socket = try Socket(ring: IORing.shared, domain: sa_family_t(AF_UNIX), type: SOCK_DGRAM)
    // mstpd needs the client bound to its own (abstract) name to have a reply address;
    // both ends address with the full sizeof(sockaddr_un), so the abstract name is just
    // sun_path[0] = 0 followed by the (NUL-padded) name.
    try _socket.bind(to: Self._abstractAddress("SwiftMSTP_\(getpid())"))
    try await _socket.connect(to: Self._abstractAddress(Self.serverName))
  }

  // CIST (instance 0) port status for a bridge/port by ifindex, or nil on any error.
  public func cistPortStatus(bridgeIndex: Int32, portIndex: Int32) async -> MSTPCISTPortStatus? {
    var request = [UInt8]()
    func append(_ v: Int32) { withUnsafeBytes(of: v) { request.append(contentsOf: $0) } }
    append(Self.cmdGetCISTPortStatus) // cmd
    append(8) // lin = sizeof(get_cist_port_status_IN)
    append(Int32(Self.cistPortStatusSize)) // lout
    append(Int32(Self.logBufferSize - 1)) // llog
    append(0) // res (unused in request)
    append(bridgeIndex) // IN.br_index
    append(portIndex) // IN.port_index

    let socket = _socket // Sendable; the single serial caller means no concurrent socket use
    let outgoing = request // freeze for the @Sendable closure
    let count = Self.headerSize + Self.cistPortStatusSize + Self.logBufferSize
    let reply: [UInt8]
    do {
      reply = try await _withTimeout(.seconds(1)) {
        try await socket.send(outgoing)
        return try await socket.receive(count: count)
      }
    } catch {
      return nil
    }
    guard reply.count >= Self.headerSize + Self.cistPortStatusSize else { return nil }

    func int32(at offset: Int) -> Int32 {
      reply.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
    }
    guard int32(at: Self.resOffset) == 0 else { return nil } // mstpd handler result
    let out = Self.headerSize
    guard let role = MSTPPortRole(rawValue: int32(at: out + Self.roleOffset)),
          let state = MSTPPortState(rawValue: int32(at: out + Self.stateOffset))
    else { return nil }
    return MSTPCISTPortStatus(role: role, state: state)
  }

  // sockaddr_un whose abstract name is sun_path[0] = 0 followed by the name. On Linux
  // sockaddr_un.size is the full struct size, which is the length mstpd uses.
  private static func _abstractAddress(_ name: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { path in
      for (i, b) in name.utf8.enumerated() {
        path[i + 1] = b
      } // [0] stays NUL (abstract)
    }
    return address
  }
  #else
  public init() async throws { throw POSIXError(.ENOSYS) }
  public func cistPortStatus(bridgeIndex: Int32, portIndex: Int32) async -> MSTPCISTPortStatus? {
    nil
  }
  #endif
}

private struct MSTPTimedOut: Error {}

// Run an async operation with a deadline; throws MSTPTimedOut (cancelling the operation) if it
// does not finish in time. Bounds the mstpd round-trip so a wedged daemon can't stall the caller.
private func _withTimeout<R: Sendable>(
  _ duration: Duration,
  _ operation: @escaping @Sendable () async throws -> R
) async throws -> R {
  try await withThrowingTaskGroup(of: R.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw MSTPTimedOut()
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
