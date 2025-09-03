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
struct MRPHandler<P: Port>: Sendable {
  private nonisolated let _controller: Weak<MRPController<P>>

  private var controller: MRPController<P>? {
    _controller.object
  }

  init(controller: MRPController<P>) {
    _controller = Weak(controller)
  }

  struct Port: Encodable, Sendable {
    let portNumber: P.ID
    let portName: String
    let leaveTime: Int

    private init(portNumber: P.ID, portName: String, leaveTime: Int) {
      self.portNumber = portNumber
      self.portName = portName
      self.leaveTime = leaveTime
    }

    fileprivate init(controller: MRPController<P>, port: P) {
      let leaveTime = controller.timerConfiguration.leaveTime.milliseconds
      self.init(portNumber: port.id, portName: port.name, leaveTime: Int(leaveTime))
    }
  }

  @JSONRoute("GET /api/avb/mrp", encoder: _getSnakeCaseJSONEncoder())
  func get() async throws -> Dictionary<String, [AnyCodable]> {
    try await ["port": getPorts().map { AnyCodable($0) }]
  }

  @JSONRoute("GET /api/avb/mrp/port", encoder: _getSnakeCaseJSONEncoder())
  func getPorts() async throws -> Array<Port> {
    guard let controller else { throw HTTPUnhandledError() }
    return await controller.ports.asyncMap { Port(controller: controller, port: $0) }
  }

  @JSONRoute("GET /api/avb/mrp/port/:port", encoder: _getSnakeCaseJSONEncoder())
  func getPort(_ request: HTTPRequest) async throws -> Port {
    guard let controller, let port = await controller.getPort(request) else {
      throw HTTPUnhandledError()
    }

    return Port(controller: controller, port: port.0)
  }

  @JSONRoute("GET /api/avb/mrp/port/:port/leave_time")
  func getPortLeaveTime(_ request: HTTPRequest) async throws -> Int {
    try await getPort(request).leaveTime
  }

  @JSONRoute("GET /api/avb/mrp/port/:port/port_number")
  func getPortPortNumber(_ request: HTTPRequest) async throws -> AnyCodable {
    try await AnyCodable(getPort(request).portNumber)
  }
}
#endif
