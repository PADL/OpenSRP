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

import BinaryParsing
import IEEE802

enum MSRPPortMediaType {
  case accessControlPort
  case nonDMNSharedMediumPort
}

enum MSRPDirection {
  case talker
  case listener
}

public enum MSRPDeclarationType: Sendable, Equatable {
  case talkerAdvertise
  case talkerFailed
  case listenerAskingFailed
  case listenerReady
  case listenerReadyFailed

  // Listener Ready or Ready Failed: at least one listener is ready, so the stream reserves
  // bandwidth and gets a dynamic MDB entry (Table 35-13/35-14). Asking Failed reserves nothing.
  var isListenerReady: Bool {
    self == .listenerReady || self == .listenerReadyFailed
  }

  var attributeType: MSRPAttributeType {
    switch self {
    case .talkerAdvertise:
      return .talkerAdvertise
    case .talkerFailed:
      return .talkerFailed
    case .listenerAskingFailed:
      fallthrough
    case .listenerReady:
      fallthrough
    case .listenerReadyFailed:
      return .listener
    }
  }

  var attributeSubtype: MSRPAttributeSubtype? {
    switch self {
    case .talkerAdvertise:
      fallthrough
    case .talkerFailed:
      return nil
    case .listenerAskingFailed:
      return .askingFailed
    case .listenerReady:
      return .ready
    case .listenerReadyFailed:
      return .readyFailed
    }
  }

  var direction: MSRPDirection {
    switch self {
    case .talkerAdvertise:
      fallthrough
    case .talkerFailed:
      return .talker
    case .listenerAskingFailed:
      fallthrough
    case .listenerReady:
      fallthrough
    case .listenerReadyFailed:
      return .listener
    }
  }

  init?(attributeSubtype: AttributeSubtype?) throws {
    guard let attributeSubtype,
          let attributeSubtype = MSRPAttributeSubtype(rawValue: attributeSubtype)
    else {
      throw MRPError.invalidAttributeValue
    }
    self.init(attributeSubtype: attributeSubtype)
  }

  init?(attributeSubtype: MSRPAttributeSubtype) {
    switch attributeSubtype {
    case .ignore:
      return nil
    case .askingFailed:
      self = .listenerAskingFailed
    case .ready:
      self = .listenerReady
    case .readyFailed:
      self = .listenerReadyFailed
    }
  }
}

extension MSRPTalkerValue {
  var declarationType: MSRPDeclarationType? {
    switch self {
    case is MSRPTalkerAdvertiseValue:
      .talkerAdvertise
    case is MSRPTalkerFailedValue:
      .talkerFailed
    default:
      nil
    }
  }
}

typealias MSRPPortLatency = Int

public struct MSRPSystemID: Sendable, Equatable, ExpressibleByIntegerLiteral,
  CustomStringConvertible, Hashable, SerDes
{
  public typealias IntegerLiteralType = UInt64

  public let id: UInt64

  public init(integerLiteral id: UInt64) {
    self.id = id
  }

  public init(id: UInt64) {
    self.id = id
  }

  public var description: String {
    _formatHex(id, padToWidth: 16)
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint64: id)
  }

  public init(parsing input: inout ParserSpan) throws {
    id = try UInt64(parsing: &input, storedAsBigEndian: UInt64.self)
  }
}

public struct MSRPStreamID: Sendable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral,
  CustomStringConvertible,
  Value, Hashable
{
  public typealias IntegerLiteralType = UInt64

  public let id: UInt64

  public var index: UInt64 { id }

  public init(integerLiteral id: UInt64) {
    self.id = id
  }

  public init(stringLiteral streamIDString: String) {
    let id = UInt64(streamIDString, radix: 16)
    self.init(integerLiteral: id ?? 0)
  }

  var streamIDString: String {
    _formatHex(id, padToWidth: 16)
  }

  public var description: String {
    "0x" + streamIDString
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint64: id)
  }

  public init(parsing input: inout ParserSpan) throws {
    id = try UInt64(parsing: &input, storedAsBigEndian: UInt64.self)
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    // a peer can encode a FirstValue + NumberOfValues that overruns the 64-bit range
    // (10.8.2.8 d); reject it rather than trap on reconstruction
    let (newID, overflow) = id.addingReportingOverflow(index)
    guard !overflow else { throw MRPError.invalidAttributeValue }
    return Self(integerLiteral: newID)
  }
}

enum MSRPProtocolVersion: ProtocolVersion {
  case v0 = 0
  case v1 = 1
}

public enum TSNFailureCode: UInt8, SerDes, Equatable {
  case unknown = 0 // this is seen with LeaveAll PDUs
  case insufficientBandwidth = 1
  case insufficientBridgeResources = 2
  case insufficientBandwidthForTrafficClass = 3
  case streamIDAlreadyInUse = 4
  case streamDestinationAddressAlreadyInUse = 5
  case streamPreemptedByHigherRank = 6
  case reportedLatencyHasChanged = 7
  case egressPortIsNotAvbCapable = 8
  case useDifferentDestinationAddress = 9
  case outOfMSRPResources = 10
  case outOfMMRPResources = 11
  case cannotStoreDestinationAddress = 12
  case requestedPriorityIsNotAnSRClassPriority = 13
  case maxFrameSizeTooLargeForMedia = 14
  case fanInPortLimitReached = 15
  case changeInFirstValueForRegisteredStreamID = 16
  case vlanBlockedOnEgressPort = 17
  case vlanTaggingDisabledOnEgressPort = 18
  case srClassPriorityMismatch = 19
  case enhancedFeatureCannotBePropagated = 20
  case maxLatencyExceeded = 21
  case nearestBridgeNetworkIdentificationFailed = 22
  case streamTransformationNotSupported = 23
  case streamIDTypeNotSupportedForTransformation = 24
  case enhancedFeatureRequiresCNC = 25

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint8: rawValue)
  }

  public init(parsing input: inout ParserSpan) throws {
    guard let value = try Self(rawValue: UInt8(parsing: &input)) else {
      throw MRPError.invalidFailureCode
    }
    self = value
  }
}

public struct MSRPFailure: Error, Equatable {
  let systemID: MSRPSystemID
  let failureCode: TSNFailureCode

  public init(systemID: MSRPSystemID, failureCode: TSNFailureCode) {
    self.systemID = systemID
    self.failureCode = failureCode
  }
}

public struct MSRPTSpec: SerDes, Equatable, Hashable {
  let maxFrameSize: UInt16
  let maxIntervalFrames: UInt16

  init() {
    self.init(maxFrameSize: 0, maxIntervalFrames: 0)
  }

  init(maxFrameSize: UInt16, maxIntervalFrames: UInt16) {
    self.maxFrameSize = maxFrameSize
    self.maxIntervalFrames = maxIntervalFrames
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint16: maxFrameSize)
    serializationContext.serialize(uint16: maxIntervalFrames)
  }

  public init(parsing input: inout ParserSpan) throws {
    try self.init(
      maxFrameSize: UInt16(parsing: &input, storedAsBigEndian: UInt16.self),
      maxIntervalFrames: UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    )
  }
}

public struct MSRPDataFrameParameters: Value, Equatable, Hashable, CustomStringConvertible {
  let destinationAddress: EUI48
  let vlanIdentifier: VLAN

  private var _value: UInt64 {
    UInt64(eui48: destinationAddress)
  }

  public var index: UInt64 {
    _value
  }

  public static func == (lhs: MSRPDataFrameParameters, rhs: MSRPDataFrameParameters) -> Bool {
    _isEqualMacAddress(lhs.destinationAddress, rhs.destinationAddress) && lhs.vlanIdentifier == rhs
      .vlanIdentifier
  }

  public func hash(into hasher: inout Hasher) {
    _hashMacAddress(destinationAddress, into: &hasher)
    vlanIdentifier.hash(into: &hasher)
  }

  public var description: String {
    "MSRPDataFrameParameters(destinationAddress: \(_macAddressToString(destinationAddress)), vlanIdentifier: \(vlanIdentifier.vid))"
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize([
      destinationAddress[0],
      destinationAddress[1],
      destinationAddress[2],
      destinationAddress[3],
      destinationAddress[4],
      destinationAddress[5],
    ])
    try vlanIdentifier.serialize(into: &serializationContext)
  }

  init(destinationAddress: EUI48, vlanIdentifier: VLAN) {
    self.destinationAddress = destinationAddress
    self.vlanIdentifier = vlanIdentifier
  }

  public init(parsing input: inout ParserSpan) throws {
    destinationAddress = try _eui48(parsing: &input)
    vlanIdentifier = try VLAN(parsing: &input)
  }

  init() {
    // set VLAN identifier to zero for correct Null value encoding
    try! self.init(destinationAddress: UInt64(0).asEUI48(), vlanIdentifier: VLAN(vid: 0))
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    let destinationAddress = try (UInt64(eui48: destinationAddress) + index).asEUI48()
    return Self(destinationAddress: destinationAddress, vlanIdentifier: vlanIdentifier)
  }
}

public struct MSRPPriorityAndRank: SerDes, Equatable, Hashable, Comparable,
  CustomStringConvertible
{
  public static func < (lhs: MSRPPriorityAndRank, rhs: MSRPPriorityAndRank) -> Bool {
    lhs.value < rhs.value
  }

  let value: UInt8

  // 35.2.2.8.5(c): the 4-bit Reserved field is zero-filled on transmit and
  // ignored on receive, so mask it off everywhere it is constructed
  init(_ value: UInt8 = 0) {
    self.value = value & 0xF0
  }

  public init(dataFramePriority: SRclassPriority, rank: Bool = false) {
    value = dataFramePriority.rawValue << 5 | (rank ? 0x10 : 0x00)
  }

  public init(parsing input: inout ParserSpan) throws {
    value = try UInt8(parsing: &input) & 0xF0
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint8: value)
  }

  public var dataFramePriority: SRclassPriority {
    IEEE802Packet.TCI.PCP(rawValue: UInt8((value & 0xE0) >> 5))!
  }

  public var rank: Bool {
    value & 0x10 != 0
  }

  public var description: String {
    // rank bit 0 is emergency, 1 non-emergency (35.2.2.8.5(c))
    "priority \(dataFramePriority) rank \(rank ? "normal" : "emergency")"
  }
}

public enum SRclassID: UInt8, Sendable, CaseIterable, CustomStringConvertible {
  case A = 6
  case B = 5
  case C = 4
  case D = 3
  case E = 2
  case F = 1
  case G = 0

  var classMeasurementInterval: Int {
    get throws {
      switch self {
      case .A:
        125
      case .B:
        250
      default:
        throw MRPError.invalidSRclassID
      }
    }
  }

  public var description: String {
    switch self {
    case .A: "A"
    case .B: "B"
    case .C: "C"
    case .D: "D"
    case .E: "E"
    case .F: "F"
    case .G: "G"
    }
  }
}

public typealias SRclassPriority = IEEE802Packet.TCI.PCP

public typealias SRclassVID = VLAN.ID

public let SR_PVID = VLAN(vid: 2)

// The AVB maximum frame size (octets, excluding media framing): the reference
// size for stream latency (35.2.2.8.4). A port whose MTU exceeds this can't
// bound stream latency and is treated as not AVB capable. It also serves as
// msrpLatencyMaxFrameSize, the worst-case interfering-frame size (35.2.2.8.6).
public let AVBMaxFrameSize: UInt = 2000

// The per-hop SRUW7F0D[/DWHQF\ (35.2.2.8.6), summing only the terms observable from this daemon:
//   d) wire propagation: the gPTP meanLinkDelay (caller supplies it, in ns)
//   c) internal processing: store-and-forward of the frame -- one max-size frame time at the
//      egress link rate
//   b) lower-priority interference: one max-size (msrpLatencyMaxFrameSize) frame that could have
//      just begun transmitting -- another frame time at the egress link rate
//   e) media access delay: ~0 on a full-duplex switched link
// Term a) -- the time to drain the equal/higher-priority queues -- depends on the switch's
// credit-based-shaper credit state and queue depths, which are not observable here (the standard
// also declines to specify it, 35.2.2.8.6 note), so it is not included.
func srpPortTcMaxLatency(
  meanLinkDelayNs: Int,
  linkSpeedKbps: UInt,
  maxFrameSize: UInt = AVBMaxFrameSize
) -> Int {
  var latency = meanLinkDelayNs
  if linkSpeedKbps > 0 {
    // one max-size frame time in ns: bytes * 8 bits / (kbps * 1000) s, scaled to ns.
    // Compute in UInt64: maxFrameSize * 8_000_000 (e.g. 2000 * 8e6 = 1.6e10) overflows a 32-bit
    // UInt and traps on the armhf target before the divide.
    let frameTimeNs = Int(UInt64(maxFrameSize) * 8_000_000 / UInt64(linkSpeedKbps))
    latency += 2 * frameTimeNs // c) store-and-forward + b) one interfering lower-priority frame
  }
  return latency
}
