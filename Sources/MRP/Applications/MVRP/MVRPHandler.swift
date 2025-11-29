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

@HTTPHandler
struct MVRPHandler<P: Port>: Sendable, RestApiApplicationHandler {
  typealias Controller = MRPController<P>
  typealias Application = MVRPApplication<P>

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

  struct VLAN: Encodable, Sendable {
    let vid: UInt16
    let registered: Bool
    let declared: Bool

    fileprivate init(attributeValue: AttributeValue) {
      vid = (attributeValue.attributeValue as! MVRPVIDValue).vid
      registered = attributeValue.isRegistered
      declared = attributeValue.isDeclared
    }
  }

  struct Port: Encodable, Sendable {
    let portNumber: P.ID
    let portName: String
    let enabled: Bool
    let vlan: [VLAN]

    fileprivate init(participant: Participant<Application>) async {
      let port = participant.port

      portNumber = port.id
      portName = port.name
      enabled = true
      vlan = await participant.findAllAttributes(
        attributeType: MVRPAttributeType.vid.rawValue,
        matching: .matchAny
      ).map { VLAN(attributeValue: $0) }
    }
  }

  @JSONRoute("GET /api/avb/mvrp", encoder: _getSnakeCaseJSONEncoder())
  func get() async throws -> Dictionary<String, [AnyCodable]> {
    try await ["port": getPorts().map { AnyCodable($0) }]
  }

  @JSONRoute("GET /api/avb/mvrp/port", encoder: _getSnakeCaseJSONEncoder())
  func getPorts() async throws -> Array<Port> {
    let application = try requireApplication()
    return await application.apply { participant in
      await Port(participant: participant)
    }
  }

  @JSONRoute("GET /api/avb/mvrp/port/:port_number", encoder: _getSnakeCaseJSONEncoder())
  func getPort(_ request: HTTPRequest) async throws -> Port {
    let (_, _, participant) = try await getApplicationPortAndParticipant(from: request)
    return await Port(participant: participant)
  }

  @JSONRoute("GET /api/avb/mvrp/port/:port_number/vlan/:vid", encoder: _getSnakeCaseJSONEncoder())
  func getPortVlan(_ request: HTTPRequest) async throws -> VLAN {
    guard let application, let (port, vlan) = await controller?.getPortAndVlan(request) else {
      throw HTTPUnhandledError()
    }

    guard let vlan = try await Port(participant: application.findParticipant(port: port)).vlan
      .first(where: { $0.vid == vlan.id })
    else {
      throw HTTPUnhandledError()
    }

    return vlan
  }

  @JSONRoute(
    "GET /api/avb/mvrp/port/:port_number/vlan/:vid/vid",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getPortVlanVid(_ request: HTTPRequest) async throws -> UInt16 {
    try await getPortVlan(request).vid
  }

  @JSONRoute(
    "GET /api/avb/mvrp/port/:port_number/vlan/:vid/registered",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getPortVlanRegistered(_ request: HTTPRequest) async throws -> Bool {
    try await getPortVlan(request).registered
  }

  @JSONRoute(
    "GET /api/avb/mvrp/port/:port_number/vlan/:vid/declared",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getPortVlanDeclared(_ request: HTTPRequest) async throws -> Bool {
    try await getPortVlan(request).declared
  }

  @JSONRoute("GET /api/avb/mvrp/port/:port_number/enabled", encoder: _getSnakeCaseJSONEncoder())
  func getPortEnabled(_ request: HTTPRequest) async throws -> Bool {
    try await getPort(request).enabled
  }

  @JSONRoute("GET /api/avb/mvrp/port/:port_number/port_number", encoder: _getSnakeCaseJSONEncoder())
  func getPortNumber(_ request: HTTPRequest) async throws -> AnyCodable {
    try await AnyCodable(getPort(request).portNumber)
  }

  @JSONRoute("GET /api/avb/mvrp/port/:port_number/vlan", encoder: _getSnakeCaseJSONEncoder())
  func getPortVlans(_ request: HTTPRequest) async throws -> Array<VLAN> {
    try await getPort(request).vlan
  }
}
#endif
