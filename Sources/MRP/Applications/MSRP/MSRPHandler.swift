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
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Glibc)
import Glibc
#endif
import FlyingFox
import FlyingFoxMacros
import IEEE802

@HTTPHandler
struct MSRPHandler<P: AVBPort>: Sendable, RestApiApplicationHandler {
  typealias Controller = MRPController<P>
  typealias Application = MSRPApplication<P>

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

  struct Talker: Encodable, Sendable {
    let streamID: String
    let accumulatedLatency: Int
    let destination: String
    let registered: Bool
    let declared: Bool

    fileprivate init(attributeValue: AttributeValue) {
      let talker = attributeValue.attributeValue as! MSRPTalkerAdvertiseValue
      streamID = talker.streamID.streamIDString
      accumulatedLatency = Int(talker.accumulatedLatency)
      destination = _macAddressToString(talker.dataFrameParameters.destinationAddress)
      registered = attributeValue.registrarState?.isRegistered ?? false
      declared = attributeValue.applicantState.isDeclared
    }
  }

  struct TalkerFailed: Encodable, Sendable {
    let streamID: String
    let failureCode: Int
    let failureReason: String
    let systemID: String
    let accumulatedLatency: Int
    let destination: String
    let registered: Bool
    let declared: Bool

    fileprivate init(attributeValue: AttributeValue) {
      let talkerFailed = attributeValue.attributeValue as! MSRPTalkerFailedValue
      streamID = talkerFailed.streamID.streamIDString
      failureCode = Int(talkerFailed.failureCode.rawValue)
      failureReason = String(describing: talkerFailed.failureCode)
      systemID = _formatHex(talkerFailed.systemID, padToWidth: 16)
      accumulatedLatency = Int(talkerFailed.accumulatedLatency)
      destination = _macAddressToString(talkerFailed.dataFrameParameters.destinationAddress)
      registered = attributeValue.registrarState?.isRegistered ?? false
      declared = attributeValue.applicantState.isDeclared
    }
  }

  struct Listener: Encodable, Sendable {
    let streamID: String
    let type: String
    let registered: Bool
    let declared: Bool

    fileprivate init(attributeValue: AttributeValue) {
      let listener = attributeValue.attributeValue as! MSRPListenerValue
      streamID = listener.streamID.streamIDString

      var type: String!

      if let attributeSubtype = attributeValue.attributeSubtype,
         let subtype = MSRPAttributeSubtype(rawValue: attributeSubtype)
      {
        switch subtype {
        case .ready: type = "ready"
        case .readyFailed: type = "ready_failed"
        case .askingFailed: type = "asking_failed"
        default: break
        }
      }
      self.type = type ?? ""
      registered = attributeValue.registrarState?.isRegistered ?? false
      declared = attributeValue.applicantState.isDeclared
    }
  }

  struct SRClass: Encodable, Sendable {
    let deltaBandwidth: Int
    let present: Bool
    let domainBoundaryPort: Bool
    let vid: UInt16
    let srClassID: UInt8
    let priority: UInt8
    let operIdleSlope: Int

    fileprivate init?(
      application: Application,
      participant: Participant<Application>,
      srClassID: SRclassID,
      streams: [Stream]
    ) {
      deltaBandwidth = application._deltaBandwidths[srClassID] ?? 0
      let portState = application.withPortState(port: participant.port) { $0 }
      guard let domain = portState.getDomain(for: srClassID, defaultSRPVid: application._srPVid)
      else { return nil }
      domainBoundaryPort = portState.srpDomainBoundaryPort[srClassID] ?? true
      vid = domain.srClassVID
      self.srClassID = srClassID.rawValue
      let priority = portState.srClassPriorityMap[srClassID]?.rawValue ?? 0
      self.priority = priority
      let streams = streams.filter { $0.priority == priority }
      present = !streams.isEmpty

      // Calculate operIdleSlope based on CBSParams.swift logic
      operIdleSlope = Self._calculateOperIdleSlope(
        application: application,
        port: participant.port,
        srClassID: srClassID,
        streams: streams
      )
    }

    private static func _calculateOperIdleSlope(
      application: Application,
      port: P,
      srClassID: SRclassID,
      streams: [Stream]
    ) -> Int {
      var idleslope = 0

      for stream in streams {
        idleslope += stream.bandwidth
      }

      // Convert from bits/sec to bits/ms for idle slope calculation
      return Int(ceil(Double(idleslope) / 1000.0))
    }
  }

  struct Stream: Encodable, Sendable {
    struct Talker: Encodable, Sendable {
      let portNumber: P.ID
      let portName: String
      let type: String

      fileprivate init(participant: Participant<Application>, attributeValue: AttributeValue) {
        portNumber = participant.port.id
        portName = participant.port.name

        type = switch MSRPAttributeType(rawValue: attributeValue.attributeType) {
        case .talkerAdvertise: "talker_advertise"
        case .talkerFailed: "talker_failed"
        default: ""
        }
      }
    }

    struct Listener: Encodable, Sendable {
      let portNumber: P.ID
      let portName: String
      let connected: Bool
      let type: String
      let streamAge: UInt32

      fileprivate init(participant: Participant<Application>, attributeValue: AttributeValue) {
        portNumber = participant.port.id
        portName = participant.port.name

        let subtype: MSRPAttributeSubtype? = if let attributeSubtype = attributeValue
          .attributeSubtype
        {
          MSRPAttributeSubtype(rawValue: attributeSubtype)
        } else {
          nil
        }

        connected = subtype == .ready && (attributeValue.registrarState?.isRegistered ?? false)

        type = switch subtype {
        case .ready: "ready"
        case .readyFailed: "ready_failed"
        case .askingFailed: "asking_failed"
        default: ""
        }

        let streamID = (attributeValue.attributeValue as! MSRPListenerValue).streamID

        streamAge = if let application = participant.application {
          application.withPortState(port: participant.port) { $0.getStreamAge(for: streamID) }
        } else {
          0
        }
      }
    }

    let streamID: String
    let vid: UInt16
    let priority: UInt8
    let bandwidth: Int
    let destination: String
    let rank: String
    let talker: Talker
    let listener: [Listener]

    fileprivate init(
      application: Application,
      participant: Participant<Application>,
      attributeValue: AttributeValue
    ) async throws {
      let talker = attributeValue.attributeValue as! any MSRPTalkerValue
      let portState = application.withPortState(port: participant.port) { $0 }

      streamID = talker.streamID.streamIDString
      vid = talker.dataFrameParameters.vlanIdentifier.vid
      priority = talker.priorityAndRank.dataFramePriority.rawValue
      if let talker = talker as? MSRPTalkerAdvertiseValue {
        bandwidth = try application._calculateBandwidthUsed(portState: portState, talker: talker)
      } else {
        bandwidth = 0
      }
      destination = _macAddressToString(talker.dataFrameParameters.destinationAddress)
      rank = talker.priorityAndRank.rank ? "non_emergency" : "emergency"
      self.talker = Talker(participant: participant, attributeValue: attributeValue)
      listener = await application.apply { participant in
        await participant._getStreamListener(streamID: talker.streamID)
      }.compactMap { $0 }
    }
  }

  struct Port: Encodable, Sendable {
    let enabled: Bool
    let talker: [Talker]
    let talkerFailed: [TalkerFailed]
    let listener: [Listener]
    let srClass: [String: SRClass]
    let portNumber: P.ID
    let portName: String
    let transmitRate: Int
    let asCapable: Bool
    let forwarding: Bool

    fileprivate init(application: Application, participant: Participant<Application>) async {
      let port = participant.port
      let streams = await application._getStreams()

      enabled = application.withPortState(port: participant.port) { $0.msrpPortEnabledStatus }
      listener = await participant._getListeners()
      talker = await participant._getTalkers()
      talkerFailed = await participant._getTalkersFailed()
      srClass = SRclassID.allCases.reduce(into: [:]) { dict, classID in
        if let srClassInstance = SRClass(
          application: application,
          participant: participant,
          srClassID: classID,
          streams: streams
        ) {
          dict[classID.description.lowercased()] = srClassInstance
        }
      }
      portNumber = port.id
      portName = port.name
      asCapable = await (try? port.isAsCapable) ?? false
      transmitRate = await (try? application._getTransmitRate(for: participant)) ?? 0
      forwarding = application._ignoreAsCapable || asCapable
    }
  }

  struct Status: Encodable, Sendable {
    let ignoreAsCapable: Bool
    let maxTalkerAttributes: Int
    let port: [Port]
    let stream: [Stream]

    fileprivate init(application: Application) async throws {
      ignoreAsCapable = application._ignoreAsCapable
      maxTalkerAttributes = application._maxTalkerAttributes
      port = await application._getPorts()
      stream = await application._getStreams()
    }
  }

  @JSONRoute("GET /api/avb/msrp", encoder: _getSnakeCaseJSONEncoder())
  func get() async throws -> Status {
    let application = try requireApplication()
    return try await Status(application: application)
  }

  @JSONRoute("GET /api/avb/msrp/ignore_as_capable", encoder: _getSnakeCaseJSONEncoder())
  func getIgnoreAsCapable() async throws -> Bool {
    let application = try requireApplication()
    return application._ignoreAsCapable
  }

  @JSONRoute("GET /api/avb/msrp/max_talker_attributes", encoder: _getSnakeCaseJSONEncoder())
  func getMaxTalkerAttributes() async throws -> Int {
    let application = try requireApplication()
    return application._maxTalkerAttributes
  }

  @JSONRoute("GET /api/avb/msrp/port", encoder: _getSnakeCaseJSONEncoder())
  func getPorts() async throws -> Array<Port> {
    let application = try requireApplication()
    return await application._getPorts()
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number", encoder: _getSnakeCaseJSONEncoder())
  func getPort(_ request: HTTPRequest) async throws -> Port {
    let (application, _, participant) = try await getApplicationPortAndParticipant(from: request)
    return await Port(application: application, participant: participant)
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/as_capable", encoder: _getSnakeCaseJSONEncoder())
  func getPortAsCapable(_ request: HTTPRequest) async throws -> Bool {
    try await getPort(request).asCapable
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/enabled", encoder: _getSnakeCaseJSONEncoder())
  func getPortEnabled(_ request: HTTPRequest) async throws -> Bool {
    try await getPort(request).enabled
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/forwarding", encoder: _getSnakeCaseJSONEncoder())
  func getPortForwarding(_ request: HTTPRequest) async throws -> Bool {
    try await getPort(request).forwarding
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/port_number", encoder: _getSnakeCaseJSONEncoder())
  func getPortPortNumber(_ request: HTTPRequest) async throws -> AnyCodable {
    try await AnyCodable(getPort(request).portNumber)
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/listener", encoder: _getSnakeCaseJSONEncoder())
  func getListener(_ request: HTTPRequest) async throws -> Array<Listener> {
    let (_, _, participant) = try await getApplicationPortAndParticipant(from: request)
    return await participant._getListeners()
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/listener/:stream_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getListenerByStreamID(_ request: HTTPRequest) async throws -> Listener {
    guard let application,
          let (port, streamID) = await application._getPortAndStream(request),
          let participant = try? application.findParticipant(port: port)
    else {
      throw HTTPUnhandledError()
    }

    guard let listener = await participant._getListener(streamID: streamID) else {
      throw HTTPUnhandledError()
    }

    return listener
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/listener/:stream_id/declared",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getListenerDeclared(_ request: HTTPRequest) async throws -> Bool {
    try await getListenerByStreamID(request).declared
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/listener/:stream_id/registered",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getListenerRegistered(_ request: HTTPRequest) async throws -> Bool {
    try await getListenerByStreamID(request).registered
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/listener/:stream_id/stream_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getListenerStreamID(_ request: HTTPRequest) async throws -> String {
    try await getListenerByStreamID(request).streamID
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/listener/:stream_id/type",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getListenerType(_ request: HTTPRequest) async throws -> String {
    try await getListenerByStreamID(request).type
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/sr_class", encoder: _getSnakeCaseJSONEncoder())
  func getSRClass(_ request: HTTPRequest) async throws -> Dictionary<String, SRClass> {
    try await getPort(request).srClass
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/sr_class/a", encoder: _getSnakeCaseJSONEncoder())
  func getSRClassA(_ request: HTTPRequest) async throws -> SRClass {
    guard let srClass = try await getSRClass(request)["a"] else {
      throw HTTPUnhandledError()
    }

    return srClass
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/a/delta_bandwidth",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassADeltaBandwidth(_ request: HTTPRequest) async throws -> Int {
    try await getSRClassA(request).deltaBandwidth
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/a/domain_boundary_port",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassADomainBoundaryPort(_ request: HTTPRequest) async throws -> Bool {
    try await getSRClassA(request).domainBoundaryPort
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/a/present",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassAPresent(_ request: HTTPRequest) async throws -> Bool {
    try await getSRClassA(request).present
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/a/priority",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassAPriority(_ request: HTTPRequest) async throws -> UInt8 {
    try await getSRClassA(request).priority
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/a/sr_class_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassASrClassID(_ request: HTTPRequest) async throws -> UInt8 {
    try await getSRClassA(request).srClassID
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/a/vid",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassAVid(_ request: HTTPRequest) async throws -> UInt16 {
    try await getSRClassA(request).vid
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/sr_class/b", encoder: _getSnakeCaseJSONEncoder())
  func getSRClassB(_ request: HTTPRequest) async throws -> SRClass {
    guard let srClass = try await getSRClass(request)["b"] else {
      throw HTTPUnhandledError()
    }

    return srClass
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/b/delta_bandwidth",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassBDeltaBandwidth(_ request: HTTPRequest) async throws -> Int {
    try await getSRClassB(request).deltaBandwidth
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/b/domain_boundary_port",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassBDomainBoundaryPort(_ request: HTTPRequest) async throws -> Bool {
    try await getSRClassB(request).domainBoundaryPort
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/b/present",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassBPresent(_ request: HTTPRequest) async throws -> Bool {
    try await getSRClassB(request).present
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/b/priority",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassBPriority(_ request: HTTPRequest) async throws -> UInt8 {
    try await getSRClassB(request).priority
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/b/sr_class_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassBSrClassID(_ request: HTTPRequest) async throws -> UInt8 {
    try await getSRClassB(request).srClassID
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/sr_class/b/vid",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getSRClassBVid(_ request: HTTPRequest) async throws -> UInt16 {
    try await getSRClassB(request).vid
  }

  @JSONRoute("GET /api/avb/msrp/port/:port_number/talker", encoder: _getSnakeCaseJSONEncoder())
  func getTalker(_ request: HTTPRequest) async throws -> Array<Talker> {
    guard let application,
          let port = await controller?.getPort(request),
          let participant = try? application.findParticipant(port: port.0)
    else {
      throw HTTPUnhandledError()
    }

    return await participant._getTalkers()
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker/:stream_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerByStreamID(_ request: HTTPRequest) async throws -> Talker {
    guard let application,
          let (port, streamID) = await application._getPortAndStream(request),
          let participant = try? application.findParticipant(port: port)
    else {
      throw HTTPUnhandledError()
    }

    guard let talker = await participant._getTalker(streamID: streamID) else {
      throw HTTPUnhandledError()
    }

    return talker
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailed(_ request: HTTPRequest) async throws -> Array<TalkerFailed> {
    guard let application,
          let port = await controller?.getPort(request),
          let participant = try? application.findParticipant(port: port.0)
    else {
      throw HTTPUnhandledError()
    }

    return await participant._getTalkersFailed()
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedByStreamID(_ request: HTTPRequest) async throws -> TalkerFailed {
    guard let application,
          let (port, streamID) = await application._getPortAndStream(request),
          let participant = try? application.findParticipant(port: port)
    else {
      throw HTTPUnhandledError()
    }

    guard let talkerFailed = await participant._getTalkerFailed(streamID: streamID) else {
      throw HTTPUnhandledError()
    }

    return talkerFailed
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker/:stream_id/accumulated_latency",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerAccumulatedLatency(_ request: HTTPRequest) async throws -> Int {
    try await getTalkerByStreamID(request).accumulatedLatency
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker/:stream_id/declared",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerDeclared(_ request: HTTPRequest) async throws -> Bool {
    try await getTalkerByStreamID(request).declared
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker/:stream_id/destination",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerDestination(_ request: HTTPRequest) async throws -> String {
    try await getTalkerByStreamID(request).destination
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker/:stream_id/registered",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerRegistered(_ request: HTTPRequest) async throws -> Bool {
    try await getTalkerByStreamID(request).registered
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker/:stream_id/stream_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerStreamID(_ request: HTTPRequest) async throws -> String {
    try await getTalkerByStreamID(request).streamID
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/accumulated_latency",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedAccumulatedLatency(_ request: HTTPRequest) async throws -> Int {
    try await getTalkerFailedByStreamID(request).accumulatedLatency
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/declared",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedDeclared(_ request: HTTPRequest) async throws -> Bool {
    try await getTalkerFailedByStreamID(request).declared
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/destination",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedDestination(_ request: HTTPRequest) async throws -> String {
    try await getTalkerFailedByStreamID(request).destination
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/failure_code",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedFailureCode(_ request: HTTPRequest) async throws -> Int {
    try await getTalkerFailedByStreamID(request).failureCode
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/failure_reason",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedFailureReason(_ request: HTTPRequest) async throws -> String {
    try await getTalkerFailedByStreamID(request).failureReason
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/registered",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedRegistered(_ request: HTTPRequest) async throws -> Bool {
    try await getTalkerFailedByStreamID(request).registered
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/stream_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedStreamID(_ request: HTTPRequest) async throws -> String {
    try await getTalkerFailedByStreamID(request).streamID
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/talker_failed/:stream_id/system_id",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getTalkerFailedSystemID(_ request: HTTPRequest) async throws -> String {
    try await getTalkerFailedByStreamID(request).systemID
  }

  @JSONRoute(
    "GET /api/avb/msrp/port/:port_number/transmit_rate",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getPortTransmitRate(_ request: HTTPRequest) async throws -> Int {
    try await getPort(request).transmitRate
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/bandwidth", encoder: _getSnakeCaseJSONEncoder())
  func getStreamBandwidth(_ request: HTTPRequest) async throws -> Int {
    try await getStreamByStreamID(request).bandwidth
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/destination", encoder: _getSnakeCaseJSONEncoder())
  func getStreamDestination(_ request: HTTPRequest) async throws -> String {
    try await getStreamByStreamID(request).destination
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/listener", encoder: _getSnakeCaseJSONEncoder())
  func getStreamListener(_ request: HTTPRequest) async throws -> Array<StreamListener> {
    try await getStreamByStreamID(request).listener
  }

  @JSONRoute(
    "GET /api/avb/msrp/stream/:stream_id/listener/:port_number/connected",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getStreamListenerConnected(_ request: HTTPRequest) async throws -> Bool {
    try await getStreamListenerByStreamID(request).connected
  }

  @JSONRoute(
    "GET /api/avb/msrp/stream/:stream_id/listener/:port_number/port_number",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getStreamListenerPortNumber(_ request: HTTPRequest) async throws -> AnyCodable {
    try await AnyCodable(getStreamListenerByStreamID(request).portNumber)
  }

  @JSONRoute(
    "GET /api/avb/msrp/stream/:stream_id/listener/:port_number/type",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getStreamListenerType(_ request: HTTPRequest) async throws -> String {
    try await getStreamListenerByStreamID(request).type
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/priority", encoder: _getSnakeCaseJSONEncoder())
  func getStreamPriority(_ request: HTTPRequest) async throws -> UInt8 {
    try await getStreamByStreamID(request).priority
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/rank", encoder: _getSnakeCaseJSONEncoder())
  func getStreamRank(_ request: HTTPRequest) async throws -> String {
    try await getStreamByStreamID(request).rank
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/stream_id", encoder: _getSnakeCaseJSONEncoder())
  func getStreamStreamID(_ request: HTTPRequest) async throws -> String {
    try await getStreamByStreamID(request).streamID
  }

  // workaround swhitty/FlyingSocksMacros#2
  typealias StreamTalker = Stream.Talker

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/talker", encoder: _getSnakeCaseJSONEncoder())
  func getStreamTalker(_ request: HTTPRequest) async throws -> StreamTalker {
    try await getStreamByStreamID(request).talker
  }

  @JSONRoute(
    "GET /api/avb/msrp/stream/:stream_id/talker/port_number",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getStreamTalkerPortNumber(_ request: HTTPRequest) async throws -> AnyCodable {
    try await AnyCodable(getStreamTalker(request).portNumber)
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/talker/type", encoder: _getSnakeCaseJSONEncoder())
  func getStreamTalkerType(_ request: HTTPRequest) async throws -> String {
    try await getStreamTalker(request).type
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id/vid", encoder: _getSnakeCaseJSONEncoder())
  func getStreamVid(_ request: HTTPRequest) async throws -> UInt16 {
    try await getStreamByStreamID(request).vid
  }

  @JSONRoute("GET /api/avb/msrp/stream", encoder: _getSnakeCaseJSONEncoder())
  func getStream(_ request: HTTPRequest) async throws -> Array<Stream> {
    guard let application else {
      throw HTTPUnhandledError()
    }

    return await application._getStreams()
  }

  @JSONRoute("GET /api/avb/msrp/stream/:stream_id", encoder: _getSnakeCaseJSONEncoder())
  func getStreamByStreamID(_ request: HTTPRequest) async throws -> Stream {
    guard let application, let streamID = _getStream(request) else {
      throw HTTPUnhandledError()
    }

    guard let stream = await application._getStream(streamID: streamID) else {
      throw HTTPUnhandledError()
    }

    return stream
  }

  // workaround swhitty/FlyingSocksMacros#2
  typealias StreamListener = Stream.Listener

  @JSONRoute(
    "GET /api/avb/msrp/stream/:stream_id/listener/:port_number",
    encoder: _getSnakeCaseJSONEncoder()
  )
  func getStreamListenerByStreamID(_ request: HTTPRequest) async throws -> StreamListener {
    guard let application,
          let (streamID, port) = await application._getStreamAndPort(request),
          let participant = try? application.findParticipant(port: port)
    else {
      throw HTTPUnhandledError()
    }

    guard let stream = await participant._getStreamListener(streamID: streamID) else {
      throw HTTPUnhandledError()
    }

    return stream
  }
}

fileprivate extension MSRPApplication {
  func _getTransmitRate(for participant: Participant<MSRPApplication>) async throws -> Int {
    let portState = withPortState(port: participant.port) { $0 }
    let bandwidthUsed = try await _calculateBandwidthUsed(
      participant: participant,
      portState: portState
    )
    return bandwidthUsed.values.reduce(0, +)
  }

  func _getPorts() async -> [MSRPHandler<P>.Port] {
    await apply { await MSRPHandler<P>.Port(application: self, participant: $0) }
  }

  private func _getRegisteredStreams(matching filter: AttributeValueFilter) async
    -> [MSRPHandler<P>.Stream]
  {
    await apply { participant in
      await participant.findAllAttributes(matching: filter)
        .filter {
          $0.attributeValue is any MSRPTalkerValue && $0.registrarState?.isRegistered ?? false
        }
        .asyncMap {
          try? await MSRPHandler<A.P>.Stream(
            application: self,
            participant: participant,
            attributeValue: $0
          )
        }
        .compactMap { $0 }
    }.flatMap { $0 }
  }

  func _getStreams() async -> [MSRPHandler<P>.Stream] {
    await _getRegisteredStreams(matching: .matchAny)
  }

  func _getStream(streamID: MSRPStreamID) async -> MSRPHandler<P>.Stream? {
    await _getRegisteredStreams(matching: .matchIndex(streamID)).first
  }

  func _getStream(streamID: String) async -> MSRPHandler<P>.Stream? {
    let streamID = MSRPStreamID(stringLiteral: streamID)
    guard streamID != 0 else { return nil }
    return await _getStream(streamID: streamID)
  }
}

fileprivate extension Participant where A.P: AVBPort {
  func _getListeners() -> [MSRPHandler<A.P>.Listener] {
    findAllAttributes(
      attributeType: MSRPAttributeType.listener.rawValue,
      matching: .matchAny
    ).map { MSRPHandler<A.P>.Listener(attributeValue: $0) }
  }

  func _getListener(streamID: MSRPStreamID) -> MSRPHandler<A.P>.Listener? {
    findAllAttributes(
      attributeType: MSRPAttributeType.listener.rawValue,
      matching: .matchIndex(streamID)
    ).map { MSRPHandler<A.P>.Listener(attributeValue: $0) }
      .first
  }
}

fileprivate extension Participant where A.P: AVBPort {
  func _getTalkers() -> [MSRPHandler<A.P>.Talker] {
    findAllAttributes(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchAny
    ).map { MSRPHandler<A.P>.Talker(attributeValue: $0) }
  }

  func _getTalker(streamID: MSRPStreamID) -> MSRPHandler<A.P>.Talker? {
    findAllAttributes(
      attributeType: MSRPAttributeType.talkerAdvertise.rawValue,
      matching: .matchIndex(streamID)
    )
    .map { MSRPHandler<A.P>.Talker(attributeValue: $0) }
    .first
  }
}

fileprivate extension Participant where A.P: AVBPort {
  func _getTalkersFailed() -> [MSRPHandler<A.P>.TalkerFailed] {
    findAllAttributes(
      attributeType: MSRPAttributeType.talkerFailed.rawValue,
      matching: .matchAny
    ).map { MSRPHandler<A.P>.TalkerFailed(attributeValue: $0) }
  }

  func _getTalkerFailed(streamID: MSRPStreamID) -> MSRPHandler<A.P>.TalkerFailed? {
    findAllAttributes(
      attributeType: MSRPAttributeType.talkerFailed.rawValue,
      matching: .matchIndex(streamID)
    )
    .map { MSRPHandler<A.P>.TalkerFailed(attributeValue: $0) }
    .first
  }
}

fileprivate extension Participant where A.P: AVBPort {
  func _getStreamListener(streamID: MSRPStreamID) -> MSRPHandler<A.P>.Stream.Listener? {
    findAllAttributes(
      attributeType: MSRPAttributeType.listener.rawValue,
      matching: .matchIndex(streamID)
    ).map { MSRPHandler<A.P>.Stream.Listener(
      participant: self as! Participant<MSRPApplication<A.P>>,
      attributeValue: $0
    ) }.first
  }
}

func _getStream(_ request: HTTPRequest) -> MSRPStreamID? {
  guard let url = URL(string: request.path) else { return nil }
  guard let (streamIDString, _) = url.getComponentPrecededBy("stream") else { return nil }

  let streamID = MSRPStreamID(stringLiteral: streamIDString)
  guard streamID != 0 else { return nil }
  return streamID
}

fileprivate extension MSRPApplication {
  // /api/avb/msrp/port/:port_number/{listener|talker|talker_failed}/:stream_id/... -> portID, streamID
  func _getPortAndStream(_ request: HTTPRequest) async -> (P, MSRPStreamID)? {
    guard let (port, residual) = await controller?.getPort(request) else { return nil }

    // Remove only the first "/" component if present
    var components = residual.pathComponents
    if components.first == "/" {
      components.removeFirst()
    }
    guard components.count > 1 else { return nil }

    // Check if path goes through listener/talker/talker_failed
    switch components[0] {
    case "listener", "talker", "talker_failed":
      let streamIDString = components[1]
      let streamID = MSRPStreamID(stringLiteral: streamIDString)
      guard streamID != 0 else { return nil }
      return (port, streamID)
    default:
      return nil
    }
  }

  // /api/avb/msrp/stream/:stream_id/.../port/:port_number/... -> streamID, portID
  func _getStreamAndPort(_ request: HTTPRequest) async -> (MSRPStreamID, P)? {
    guard let url = URL(string: request.path),
          let (streamID, residual) = url
          .extractParameter(after: "stream", as: MSRPStreamID.self, validator: { streamString in
            let id = MSRPStreamID(stringLiteral: streamString)
            return id != 0 ? id : nil
          }),
          let (port, _) = await controller?.getPort(residual) else { return nil }
    return (streamID, port)
  }
}

#endif
