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

import AnyCodable
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FlyingFox
import FlyingFoxMacros
import IEEE802

@HTTPHandler
struct MMRPHandler<P: Port>: Sendable, RestApiApplicationHandler {
  typealias Controller = MRPController<P>
  typealias Application = MMRPApplication<P>

  private nonisolated let _application: Weak<Application>

  var application: Application? {
    _application.object
  }

  var controller: Controller? {
    application?.controller
  }

  init(application: Application) {
    _application = Weak(application)
  }

  struct MAC: Encodable, Sendable {
    let mac: String
    let registered: Bool
    let declared: Bool

    fileprivate init(attributeValue: AttributeValue) {
      let macValue = attributeValue.attributeValue as! MMRPMACValue
      mac = _macAddressToString(macValue.macAddress)
      registered = attributeValue.registrarState?.isRegistered ?? false
      declared = attributeValue.applicantState.isDeclared
    }
  }

  struct Port: Encodable, Sendable {
    let portNumber: P.ID
    let portName: String
    let enabled: Bool
    let mac: [MAC]

    fileprivate init(participant: Participant<Application>) async {
      let port = participant.port

      portNumber = port.id
      portName = port.name
      enabled = true
      mac = await participant.findAllAttributes(
        attributeType: MMRPAttributeType.mac.rawValue,
        matching: .matchAny
      ).map { MAC(attributeValue: $0) }
    }
  }

  @JSONRoute("GET /api/avb/mmrp", encoder: _getSnakeCaseJSONEncoder())
  func get() async throws -> Dictionary<String, [AnyCodable]> {
    try await ["port": getPorts().map { AnyCodable($0) }]
  }

  @JSONRoute("GET /api/avb/mmrp/port", encoder: _getSnakeCaseJSONEncoder())
  func getPorts() async throws -> Array<Port> {
    let application = try requireApplication()
    return await application.apply { participant in
      await Port(participant: participant)
    }
  }

  @JSONRoute("GET /api/avb/mmrp/port/:port_number", encoder: _getSnakeCaseJSONEncoder())
  func getPort(_ request: HTTPRequest) async throws -> Port {
    let (_, _, participant) = try await getApplicationPortAndParticipant(from: request)
    return await Port(participant: participant)
  }

  @JSONRoute("GET /api/avb/mmrp/port/:port_number/mac/:mac", encoder: _getSnakeCaseJSONEncoder())
  func getPortMacAddress(_ request: HTTPRequest) async throws -> MAC {
    guard let application,
          let (port, macValue) = await controller?.getPortAndMacAddress(request)
    else {
      throw HTTPUnhandledError()
    }

    guard let mac = try await Port(participant: application.findParticipant(port: port)).mac
      .first(where: { $0.mac == _macAddressToString(macValue.macAddress) })
    else {
      throw HTTPUnhandledError()
    }

    return mac
  }

  @JSONRoute(
    "GET /api/avb/mmrp/port/:port_number/mac/:mac/mac",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getPortMacAddressAddress(_ request: HTTPRequest) async throws -> String {
    try await getPortMacAddress(request).mac
  }

  @JSONRoute(
    "GET /api/avb/mmrp/port/:port_number/mac/:mac/registered",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getPortMacAddressRegistered(_ request: HTTPRequest) async throws -> Bool {
    try await getPortMacAddress(request).registered
  }

  @JSONRoute(
    "GET /api/avb/mmrp/port/:port_number/mac/:mac/declared",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getPortMacAddressDeclared(_ request: HTTPRequest) async throws -> Bool {
    try await getPortMacAddress(request).declared
  }

  @JSONRoute("GET /api/avb/mmrp/port/:port_number/enabled", encoder: _getSnakeCaseJSONEncoder())
  func getPortEnabled(_ request: HTTPRequest) async throws -> Bool {
    try await getPort(request).enabled
  }

  @JSONRoute("GET /api/avb/mmrp/port/:port_number/port_number", encoder: _getSnakeCaseJSONEncoder())
  func getPortNumber(_ request: HTTPRequest) async throws -> AnyCodable {
    try await AnyCodable(getPort(request).portNumber)
  }

  @JSONRoute("GET /api/avb/mmrp/port/:port_number/mac", encoder: _getSnakeCaseJSONEncoder())
  func getPortMacAddresses(_ request: HTTPRequest) async throws -> Array<MAC> {
    try await getPort(request).mac
  }
}
#endif
