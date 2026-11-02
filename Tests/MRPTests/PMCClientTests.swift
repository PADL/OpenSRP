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

import BinaryParsing
import Foundation
import IEEE802
@testable import PMC
import SystemPackage
import XCTest
#if os(Linux)
import Glibc
#endif

final class PMCClientTests: XCTestCase {
  // MARK: - transportSpecific

  func testTransportSpecificIsTheHeaderHighNibble() throws {
    for transportSpecific: UInt8 in [0, 1, 0xF] {
      let request = PTPManagementClient._makeRequest(
        transportSpecific: transportSpecific,
        domainNumber: 0,
        sourcePortIdentity: PTP.PortIdentity(),
        targetPortIdentity: PTP.PortIdentity(),
        sequenceId: 1,
        action: .get,
        managementTLV: PTPManagementTLV(managementId: Priority1.managementId)
      )
      let bytes = try request.serialized()
      XCTAssertEqual(bytes[0], transportSpecific << 4 | 0x0D)
      let header = try bytes.withParserSpan { try PTP.Header(parsing: &$0) }
      XCTAssertEqual(header.majorSdoId, transportSpecific)
      XCTAssertEqual(header.messageType, .Management)
    }
  }

  #if os(Linux)
  func testRepliesAreAcceptedOnlyWithTheConfiguredTransportSpecific() async throws {
    let server = try _FakePTP4L()
    defer { server.close() }
    let pmc = try await PTPManagementClient(path: server.path, transportSpecific: 0)

    server.reply(transportSpecific: 0)
    let priority1 = try await pmc.getPriority1()
    XCTAssertEqual(priority1.priority1, 128)
    XCTAssertEqual(server.requestTransportSpecifics, [0])

    // as ptp4l would never send it: a reply with another transportSpecific is not ours
    server.reply(transportSpecific: 1)
    do {
      _ = try await pmc.getPriority1()
      XCTFail("a reply with transportSpecific 1 was accepted")
    } catch PTP.Error.responseTimedOut {}
    XCTAssertEqual(server.requestTransportSpecifics, [0, 0])
  }

  func testTransportSpecificAboveFourBitsIsRefused() async throws {
    do {
      _ = try await PTPManagementClient(path: "/nonexistent", transportSpecific: 0x10)
      XCTFail("transportSpecific 0x10 was accepted")
    } catch PTP.Error.valueTooLarge {}
  }
  #endif
}

#if os(Linux)
// A ptp4l stand-in on a datagram socket of its own: answers the next GET_PRIORITY1 with
// priority1 128 and the given transportSpecific, as uds.c does, by sendto() to the sender.
private final class _FakePTP4L: @unchecked Sendable {
  let path: String
  private let _fd: CInt
  private let _lock = NSLock()
  private var _transportSpecifics = [UInt8]()

  var requestTransportSpecifics: [UInt8] {
    _lock.withLock { _transportSpecifics }
  }

  init() throws {
    path = FileManager.default.temporaryDirectory
      .appendingPathComponent("pmc-test.\(getpid()).\(UInt32.random(in: 0...UInt32.max))").path
    _fd = socket(AF_LOCAL, Int32(SOCK_DGRAM.rawValue), 0)
    var address = try sockaddr_un(family: sa_family_t(AF_LOCAL), presentationAddress: path)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(_fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard _fd >= 0, result == 0 else {
      let error = Errno(rawValue: errno)
      Glibc.close(_fd)
      throw error
    }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  func close() {
    Glibc.close(_fd)
    unlink(path)
  }

  func reply(transportSpecific: UInt8) {
    Thread.detachNewThread { [self] in
      _replyOnce(transportSpecific: transportSpecific)
    }
  }

  private func _replyOnce(transportSpecific: UInt8) {
    var buffer = [UInt8](repeating: 0, count: 1500)
    var from = sockaddr_un()
    var fromLength = socklen_t(MemoryLayout<sockaddr_un>.size)
    let count = withUnsafeMutablePointer(to: &from) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        recvfrom(_fd, &buffer, buffer.count, 0, $0, &fromLength)
      }
    }
    guard count >= PTP.Header.Size,
          let request = try? Array(buffer[0..<count]).withParserSpan({
            try PTP.ManagementMessage(parsing: &$0)
          }) else { return }
    _lock.withLock { _transportSpecifics.append(request.header.majorSdoId) }
    guard let reply = try? PTPManagementClient._makeRequest(
      transportSpecific: transportSpecific,
      domainNumber: 0,
      sourcePortIdentity: PTP.PortIdentity(),
      targetPortIdentity: request.header.sourcePortIdentity,
      sequenceId: request.header.sequenceId,
      action: .response,
      managementTLV: PTPManagementTLV(Priority1(priority1: 128))
    ).serialized() else { return }
    _ = withUnsafePointer(to: &from) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(_fd, reply, reply.count, 0, $0, fromLength)
      }
    }
  }
}
#endif
