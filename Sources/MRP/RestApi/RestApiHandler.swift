//
// Copyright (c) 2025 PADL Software Pty Ltd
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

#if canImport(FlyingFox)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FlyingFox
import IEEE802

extension MRPController {
  // port IDs are opaque, identifiable, encodable types, so we cannot
  // directly cast one to an integer. instead, loop through all ports looking
  // for one whose string encoding matches.

  func _getPortByStringID(_ id: String) -> P? {
    ports.first { String(describing: $0.id) == id || $0.name == id }
  }

  // Simplified with new URL extension
  func getPort(_ url: URL) -> (P, URL)? {
    url.extractParameter(after: "port", as: P.self) { _getPortByStringID($0) }
  }

  func getPort(_ request: HTTPRequest) -> (P, URL)? {
    guard let url = URL(string: request.path) else { return nil }
    return getPort(url)
  }

  func getVlan(_ url: URL) -> VLAN? {
    url.extractParameter(after: "vlan", as: VLAN.self) { vlanString in
      guard let vid = UInt16(vlanString) else { return nil }
      return VLAN(id: vid)
    }?.0 // Only return the VLAN, not the residual URL
  }

  func getMacAddress(_ url: URL) -> MMRPMACValue? {
    url.extractParameter(after: "mac", as: MMRPMACValue.self) { macString in
      guard let macAddress = _stringToMacAddress(macString) else { return nil }
      return MMRPMACValue(macAddress: macAddress)
    }?.0 // Only return the MAC, not the residual URL
  }

  // Chain operations more cleanly
  func getPortAndVlan(_ request: HTTPRequest) -> (P, VLAN)? {
    guard let url = URL(string: request.path),
          let (port, residual) = getPort(url),
          let vlan = getVlan(residual) else { return nil }
    return (port, vlan)
  }

  func getPortAndMacAddress(_ request: HTTPRequest) -> (P, MMRPMACValue)? {
    guard let url = URL(string: request.path),
          let (port, residual) = getPort(url),
          let mac = getMacAddress(residual) else { return nil }
    return (port, mac)
  }

  // New: Generic multi-parameter extraction for streams
  func getPortAndStream(_ request: HTTPRequest) -> (P, MSRPStreamID)? {
    guard let url = URL(string: request.path),
          let (port, residual) = getPort(url) else { return nil }

    return residual.extractParameter(
      after: "stream",
      as: MSRPStreamID.self,
      validator: { streamString in
        let streamID = MSRPStreamID(stringLiteral: streamString)
        return streamID != 0 ? streamID : nil
      }
    ).map { (port, $0.0) }
  }
}

/// Protocol providing common validation and error handling for REST API handlers
protocol RestApiHandler<P> {
  associatedtype P: Port
  var controller: MRPController<P>? { get }
}

extension RestApiHandler {
  /// Validates that controller is available, throws HTTPUnhandledError if not
  func requireController() throws -> MRPController<P> {
    guard let controller else { throw HTTPUnhandledError() }
    return controller
  }

  /// Validates and extracts port from request
  func getPort(from request: HTTPRequest) async throws -> (P, URL) {
    let controller = try requireController()
    guard let port = await controller.getPort(request) else {
      throw HTTPUnhandledError()
    }
    return port
  }

  /// Validates and extracts port and VLAN from request
  func getPortAndVlan(from request: HTTPRequest) async throws -> (P, VLAN) {
    let controller = try requireController()
    guard let portAndVlan = await controller.getPortAndVlan(request) else {
      throw HTTPUnhandledError()
    }
    return portAndVlan
  }

  /// Validates and extracts port and MAC from request
  func getPortAndMacAddress(from request: HTTPRequest) async throws -> (P, MMRPMACValue) {
    let controller = try requireController()
    guard let portAndMAC = await controller.getPortAndMacAddress(request) else {
      throw HTTPUnhandledError()
    }
    return portAndMAC
  }

  /// Validates and extracts port and stream from request
  func getPortAndStream(from request: HTTPRequest) async throws -> (P, MSRPStreamID) {
    let controller = try requireController()
    guard let portAndStream = await controller.getPortAndStream(request) else {
      throw HTTPUnhandledError()
    }
    return portAndStream
  }
}

/// Protocol for application-specific handlers
protocol RestApiApplicationHandler<P, A>: RestApiHandler {
  associatedtype A: Application<P>
  var application: A? { get }
}

extension RestApiApplicationHandler {
  /// Validates that application is available, throws HTTPUnhandledError if not
  func requireApplication() throws -> A {
    guard let application else { throw HTTPUnhandledError() }
    return application
  }

  /// Validates and gets both application and controller
  func getApplicationAndController() throws -> (A, MRPController<P>) {
    let application = try requireApplication()
    let controller = try requireController()
    return (application, controller)
  }

  /// Validates application and finds participant for port
  func getParticipant(for port: P) async throws -> Participant<A> {
    let application = try requireApplication()
    return try await application.findParticipant(port: port)
  }

  /// Validates and extracts application, port, and participant from request
  func getApplicationPortAndParticipant(from request: HTTPRequest) async throws
    -> (A, P, Participant<A>)
  {
    let application = try requireApplication()
    let (port, _) = try await getPort(from: request)
    let participant = try await application.findParticipant(port: port)
    return (application, port, participant)
  }
}

#endif
