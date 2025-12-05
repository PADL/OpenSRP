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
import SystemPackage

public enum PTP {
  public enum Error: Swift.Error {
    case invalidManagementActionField
    case invalidManagementTLVType
    case invalidManagementTLVLength
    case messageTruncated
    case notImplemented
    case ptpVersionUnsupported
    case responseMessageTypeMismatch
    case responseTimedOut
    case unknownMessageType
    case unknownEnumerationValue
    case unknownPort
    case unknownVersion
    case unknownTLVType
    case unsupportedManagementID
    case valueTooLarge
  }

  public enum PtpVersion: UInt8, SerDes, Sendable {
    case v1 = 1
    case v2 = 2

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }
  }

  public enum MessageType: UInt8, SerDes, Sendable {
    case Sync = 0
    case Delay_Req = 1
    case Pdelay_Req = 2
    case Pdelay_Resp = 3
    case Follow_Up = 8
    case Delay_Resp = 9
    case Pdelay_Resp_Follow_Up = 10
    case Announce = 11
    case Signalling = 12
    case Management = 13

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }
  }

  enum Control: UInt8, SerDes, Sendable {
    case Sync = 0
    case Delay_Req = 1
    case Follow_Up = 2
    case Delay_Resp = 3
    case Management = 4
    case Others = 5

    func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }
  }

  public enum DelayMechanism: UInt8, SerDes, Sendable {
    case e2e = 0x01
    case p2p = 0x02
    case noMechanism = 0xFE
    case commonP2P = 0x03
    case special = 0x04

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }
  }

  public struct MajorSdoId: OptionSet, Sendable {
    public typealias RawValue = UInt8

    public let rawValue: RawValue

    public init(rawValue: RawValue) { self.rawValue = rawValue }

    public static let ieee8021AS = MajorSdoId(rawValue: 1 << 0)
    public static let cmlds = MajorSdoId(rawValue: 1 << 0)
  }

  public struct FlagField0: OptionSet, SerDes, Sendable {
    public typealias RawValue = UInt8

    public let rawValue: RawValue

    public init(rawValue: RawValue) { self.rawValue = rawValue }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      rawValue = try UInt8(parsing: &input)
    }

    public static let altMaster = FlagField0(rawValue: 1 << 0)
    public static let twoStep = FlagField0(rawValue: 1 << 1)
    public static let unicast = FlagField0(rawValue: 1 << 2)
  }

  public struct FlagField1: OptionSet, SerDes, Sendable {
    public typealias RawValue = UInt8

    public let rawValue: RawValue

    public init(rawValue: RawValue) { self.rawValue = rawValue }

    public static let leap61 = FlagField1(rawValue: 1 << 0)
    public static let leap59 = FlagField1(rawValue: 1 << 1)
    public static let utcOffsetValid = FlagField1(rawValue: 1 << 2)
    public static let ptpTimescale = FlagField1(rawValue: 1 << 3)
    public static let timeTraceable = FlagField1(rawValue: 1 << 4)
    public static let freqTraceable = FlagField1(rawValue: 1 << 5)
    public static let syncUncertain = FlagField1(rawValue: 1 << 6)

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      rawValue = try UInt8(parsing: &input)
    }
  }

  public enum PortState: UInt8, SerDes, Sendable {
    case initializing = 1
    case faulty = 2
    case disabled = 3
    case listening = 4
    case preMaster = 5
    case master = 6
    case passive = 7
    case uncalibrated = 8
    case slave = 9
    case grandMaster = 10

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }
  }

  public typealias TimeInterval = Int64

  public struct ScaledNs: SerDes, Sendable {
    public let nanosecondsMsb: Int16
    public let nanosecondsLsb: UInt64
    public let fractionalNanoseconds: UInt16

    public init(nanosecondsMsb: Int16, nanosecondsLsb: UInt64, fractionalNanoseconds: UInt16) {
      self.nanosecondsMsb = nanosecondsMsb
      self.nanosecondsLsb = nanosecondsLsb
      self.fractionalNanoseconds = fractionalNanoseconds
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(int16: nanosecondsMsb)
      serializationContext.serialize(uint64: nanosecondsLsb)
      serializationContext.serialize(uint16: fractionalNanoseconds)
    }

    public init(parsing input: inout ParserSpan) throws {
      nanosecondsMsb = try Int16(parsing: &input, storedAsBigEndian: Int16.self)
      nanosecondsLsb = try UInt64(parsing: &input, storedAsBigEndian: UInt64.self)
      fractionalNanoseconds = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    }
  }

  public struct Timestamp: SerDes, Sendable {
    public let secondsMsb: UInt16
    public let secondsLsb: UInt32
    public let nanoseconds: UInt32

    public var seconds: UInt64 {
      UInt64(secondsMsb) << 32 | UInt64(secondsLsb)
    }

    public init(secondsMsb: UInt16, secondsLsb: UInt32, nanoseconds: UInt32) {
      self.secondsMsb = secondsMsb
      self.secondsLsb = secondsLsb
      self.nanoseconds = nanoseconds
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint16: secondsMsb)
      serializationContext.serialize(uint32: secondsLsb)
      serializationContext.serialize(uint32: nanoseconds)
    }

    public init(parsing input: inout ParserSpan) throws {
      secondsMsb = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      secondsLsb = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
      nanoseconds = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
    }
  }

  public struct ClockIdentity: SerDes, Equatable, Hashable, Sendable, CustomStringConvertible {
    public static func == (lhs: PTP.ClockIdentity, rhs: PTP.ClockIdentity) -> Bool {
      lhs.id.0 == rhs.id.0 &&
        lhs.id.1 == rhs.id.1 &&
        lhs.id.2 == rhs.id.2 &&
        lhs.id.3 == rhs.id.3 &&
        lhs.id.4 == rhs.id.4 &&
        lhs.id.5 == rhs.id.5 &&
        lhs.id.6 == rhs.id.6 &&
        lhs.id.7 == rhs.id.7
    }

    public let id: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    public init(id: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) {
      self.id = id
    }

    public init(eui48: EUI48) {
      id.0 = eui48.0
      id.1 = eui48.1
      id.2 = eui48.2
      id.3 = 0xFF
      id.4 = 0xFE
      id.5 = eui48.3
      id.6 = eui48.4
      id.7 = eui48.5
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      let bytes = [id.0, id.1, id.2, id.3, id.4, id.5, id.6, id.7]
      serializationContext.serialize(bytes)
    }

    public init(parsing input: inout ParserSpan) throws {
      let bytes = try Array(parsing: &input, byteCount: 8)
      id.0 = bytes[0]
      id.1 = bytes[1]
      id.2 = bytes[2]
      id.3 = bytes[3]
      id.4 = bytes[4]
      id.5 = bytes[5]
      id.6 = bytes[6]
      id.7 = bytes[7]
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(id.0)
      hasher.combine(id.1)
      hasher.combine(id.2)
      hasher.combine(id.3)
      hasher.combine(id.4)
      hasher.combine(id.5)
      hasher.combine(id.6)
      hasher.combine(id.7)
    }

    public var description: String {
      "\(_byteToHex(id.0))\(_byteToHex(id.1))\(_byteToHex(id.2)).\(_byteToHex(id.3))\(_byteToHex(id.4)).\(_byteToHex(id.5))\(_byteToHex(id.6))\(_byteToHex(id.7))"
    }
  }

  public struct PortIdentity: SerDes, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let clockIdentity: ClockIdentity
    public let portNumber: UInt16

    public init(clockIdentity: ClockIdentity? = nil, portNumber: UInt16? = nil) {
      self.clockIdentity = clockIdentity ?? ClockIdentity(id: (
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF
      ))
      self.portNumber = portNumber ?? 0xFFFF
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      try clockIdentity.serialize(into: &serializationContext)
      serializationContext.serialize(uint16: portNumber)
    }

    public init(parsing input: inout ParserSpan) throws {
      clockIdentity = try ClockIdentity(parsing: &input)
      portNumber = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    }

    public var description: String {
      "\(clockIdentity)-\(portNumber)"
    }
  }

  public struct PortAddress: SerDes {
    public let networkProtocol: UInt16
    public let address: [UInt8]

    public init(networkProtocol: UInt16, address: [UInt8]) {
      self.networkProtocol = networkProtocol
      self.address = address
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint16: networkProtocol)
      serializationContext.serialize(address)
    }

    public init(parsing input: inout ParserSpan) throws {
      networkProtocol = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      let addressLength = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      address = try Array(parsing: &input, byteCount: Int(addressLength))
    }
  }

  public struct PhysicalAddress: SerDes {
    public let address: [UInt8]

    public init(address: [UInt8]) {
      self.address = address
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(address)
    }

    public init(parsing input: inout ParserSpan) throws {
      let addressLength = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      address = try Array(parsing: &input, byteCount: Int(addressLength))
    }
  }

  public struct ClockQuality: SerDes, Sendable {
    public let clockClass: UInt8
    public let clockAccuracy: UInt8
    public let offsetScaledLogVariance: UInt16

    public init(clockClass: UInt8, clockAccuracy: UInt8, offsetScaledLogVariance: UInt16) {
      self.clockClass = clockClass
      self.clockAccuracy = clockAccuracy
      self.offsetScaledLogVariance = offsetScaledLogVariance
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: clockClass)
      serializationContext.serialize(uint8: clockAccuracy)
      serializationContext.serialize(uint16: offsetScaledLogVariance)
    }

    public init(parsing input: inout ParserSpan) throws {
      clockClass = try UInt8(parsing: &input)
      clockAccuracy = try UInt8(parsing: &input)
      offsetScaledLogVariance = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    }
  }

  enum TLVType: UInt16, SerDes, Sendable {
    case management = 1
    case managementErrorStatus = 2
    case organizationExtension = 3
    case requestUnicastTransmission = 4
    case grantUnicastTransmission = 5
    case cancelUnicastTransmission = 6
    case acknowledgeCancelUnicastTransmission = 7
    case pathTrace = 8
    case alternateTimeOffsetIndicator = 9
    case organizationExtensionPropagate = 0x4000
    case enhancedAccuracyMetrics = 0x4001
    case organizationExtensionDoNotPropagate = 0x8000
    case l1Sync = 0x8001
    case portCommunicationAvailability = 0x8002
    case protocolAddress = 0x8003
    case slaveRxSyncTimingData = 0x8004
    case slaveRxSyncComputedData = 0x8005
    case slaveTxEventTimestamps = 0x8006
    case cumulativeRateRation = 0x8007
    case pad = 0x8008
    case authentication = 0x8009

    func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint16: rawValue)
    }

    init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }
  }

  struct OrganizationExtensionTLV: SerDes, Sendable {
    let id: (UInt8, UInt8, UInt8)
    let subtype: (UInt8, UInt8, UInt8)

    init(id: (UInt8, UInt8, UInt8), subtype: (UInt8, UInt8, UInt8)) {
      self.id = id
      self.subtype = subtype
    }

    func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize([id.0, id.1, id.2, subtype.0, subtype.1, subtype.2])
    }

    init(parsing input: inout ParserSpan) throws {
      let bytes = try Array(parsing: &input, byteCount: 6)
      id = (bytes[0], bytes[1], bytes[3])
      subtype = (bytes[3], bytes[4], bytes[5])
    }
  }

  struct L1SyncFlagField0: OptionSet, SerDes {
    typealias RawValue = UInt16

    let rawValue: RawValue

    init(rawValue: RawValue) {
      self.rawValue = rawValue
    }

    func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint16: rawValue)
    }

    init(parsing input: inout ParserSpan) throws {
      rawValue = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    }

    static let txCoherentIsRequired = L1SyncFlagField0(rawValue: 1 << 0)
    static let rxCoherentIsRequired = L1SyncFlagField0(rawValue: 1 << 1)
    static let congruentIsRequired = L1SyncFlagField0(rawValue: 1 << 2)
    static let optParamsEnabled = L1SyncFlagField0(rawValue: 1 << 3)
  }

  struct L1SyncFlagField1: OptionSet, SerDes {
    typealias RawValue = UInt16

    let rawValue: RawValue

    init(rawValue: RawValue) {
      self.rawValue = rawValue
    }

    func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint16: rawValue)
    }

    init(parsing input: inout ParserSpan) throws {
      rawValue = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    }

    static let isTxCoherent = L1SyncFlagField1(rawValue: 1 << 0)
    static let isRxCoherent = L1SyncFlagField1(rawValue: 1 << 1)
    static let isCongruent = L1SyncFlagField1(rawValue: 1 << 2)
  }

  struct L1SyncTLV: Sendable {
    let flagField0: L1SyncFlagField0
    let flagField1: L1SyncFlagField1

    init(flagField0: L1SyncFlagField0, flagField1: L1SyncFlagField1) {
      self.flagField0 = flagField0
      self.flagField1 = flagField1
    }
  }

  public struct PTPText: Sendable, SerDes, CustomStringConvertible {
    let text: [UInt8]

    init(text: [UInt8]) {
      self.text = text
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      guard text.count <= UInt8.max else { throw Error.valueTooLarge }
      serializationContext.serialize(uint8: UInt8(text.count))
      serializationContext.serialize(text)
    }

    public init(parsing input: inout ParserSpan) throws {
      let length = try UInt8(parsing: &input)
      text = try Array(parsing: &input, byteCount: Int(length))
    }

    public var description: String {
      String(decoding: text, as: UTF8.self)
    }
  }

  struct FaultRecord: Sendable, SerDes {
    let faultRecordLength: UInt16 // length excluding faultRecordLength
    let faultTime: Timestamp
    let severityCode: UInt8
    let faultName: PTPText
    let faultValue: PTPText
    let faultDescription: PTPText

    init(
      faultRecordLength: UInt16,
      faultTime: Timestamp,
      severityCode: UInt8,
      faultName: PTPText,
      faultValue: PTPText,
      faultDescription: PTPText
    ) {
      self.faultRecordLength = faultRecordLength
      self.faultTime = faultTime
      self.severityCode = severityCode
      self.faultName = faultName
      self.faultValue = faultValue
      self.faultDescription = faultDescription
    }

    func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint16: faultRecordLength)
      try faultTime.serialize(into: &serializationContext)
      serializationContext.serialize(uint8: severityCode)
      try faultName.serialize(into: &serializationContext)
      try faultValue.serialize(into: &serializationContext)
      try faultDescription.serialize(into: &serializationContext)
    }

    init(parsing input: inout ParserSpan) throws {
      faultRecordLength = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      faultTime = try Timestamp(parsing: &input)
      severityCode = try UInt8(parsing: &input)
      faultName = try PTPText(parsing: &input)
      faultValue = try PTPText(parsing: &input)
      faultDescription = try PTPText(parsing: &input)
    }
  }

  typealias RelativeDifference = Int64

  public enum ControlField: UInt8, SerDes, Sendable {
    case sync = 0x00
    case delayReq = 0x01
    case followUp = 0x02
    case delayResp = 0x03
    case management = 0x04
    case other = 0x05

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }

    init(messageType: MessageType) {
      switch messageType {
      case .Sync:
        self = .sync
      case .Delay_Req:
        self = .delayReq
      case .Follow_Up:
        self = .followUp
      case .Delay_Resp:
        self = .delayResp
      case .Management:
        self = .management
      default:
        self = .other
      }
    }
  }

  public struct Header: Sendable, SerDes {
    static let MajorSdoIdMask: UInt8 = 0xF0
    static let MessageTypeMask: UInt8 = 0x0F

    public static let Size = 34

    let majorSdoId_messageType: UInt8
    public let versionPTP: PtpVersion
    public let messageLength: UInt16
    public let domainNumber: UInt8
    public let minorSdoId: UInt8
    public let flagField0: FlagField0
    public let flagField1: FlagField1
    public let correctionField: Int64
    public let messageTypeSpecific: (UInt8, UInt8, UInt8, UInt8)
    public let sourcePortIdentity: PortIdentity
    public let sequenceId: UInt16
    let controlField: ControlField
    public let logMessageInterval: UInt8

    public var majorSdoId: UInt8 {
      majorSdoId_messageType & Self.MajorSdoIdMask >> 4
    }

    public var messageType: MessageType {
      MessageType(rawValue: majorSdoId_messageType & Self.MessageTypeMask)!
    }

    public var isEventMessage: Bool {
      messageType.rawValue < MessageType.Follow_Up.rawValue
    }

    public var isP2PMessage: Bool {
      switch messageType {
      case .Pdelay_Req:
        fallthrough
      case .Pdelay_Resp:
        fallthrough
      case .Pdelay_Resp_Follow_Up:
        return true
      default:
        return false
      }
    }

    init(
      majorSdoId_messageType: UInt8,
      versionPTP: PtpVersion,
      messageLength: UInt16,
      domainNumber: UInt8,
      minorSdoId: UInt8,
      flagField0: FlagField0,
      flagField1: FlagField1,
      correctionField: Int64,
      messageTypeSpecific: (UInt8, UInt8, UInt8, UInt8),
      sourcePortIdentity: PortIdentity,
      sequenceId: UInt16,
      controlField: ControlField,
      logMessageInterval: UInt8
    ) {
      self.majorSdoId_messageType = majorSdoId_messageType
      self.versionPTP = versionPTP
      self.messageLength = messageLength
      self.domainNumber = domainNumber
      self.minorSdoId = minorSdoId
      self.flagField0 = flagField0
      self.flagField1 = flagField1
      self.correctionField = correctionField
      self.messageTypeSpecific = messageTypeSpecific
      self.sourcePortIdentity = sourcePortIdentity
      self.sequenceId = sequenceId
      self.controlField = controlField
      self.logMessageInterval = logMessageInterval
    }

    public init(
      majorSdoId: MajorSdoId = .ieee8021AS,
      messageType: MessageType = .Management,
      versionPTP: PtpVersion = .v2,
      messageLength: UInt16,
      domainNumber: UInt8 = 0,
      minorSdoId: UInt8 = 0,
      flagField0: FlagField0 = .unicast,
      flagField1: FlagField1 = .ptpTimescale,
      correctionField: Int64 = 0,
      messageTypeSpecific: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0),
      sourcePortIdentity: PortIdentity,
      sequenceId: UInt16,
      controlField: ControlField? = nil,
      logMessageInterval: UInt8 = 0
    ) {
      let controlField = controlField ?? ControlField(messageType: messageType)
      self.init(
        majorSdoId_messageType: (majorSdoId.rawValue << 4) & Self.MajorSdoIdMask | messageType
          .rawValue & Self
          .MessageTypeMask,
        versionPTP: versionPTP,
        messageLength: messageLength,
        domainNumber: domainNumber,
        minorSdoId: minorSdoId,
        flagField0: flagField0,
        flagField1: flagField1,
        correctionField: correctionField,
        messageTypeSpecific: messageTypeSpecific,
        sourcePortIdentity: sourcePortIdentity,
        sequenceId: sequenceId,
        controlField: controlField,
        logMessageInterval: logMessageInterval
      )
    }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: majorSdoId_messageType)
      try versionPTP.serialize(into: &serializationContext)
      serializationContext.serialize(uint16: messageLength)
      serializationContext.serialize(uint8: domainNumber)
      serializationContext.serialize(uint8: minorSdoId)
      try flagField0.serialize(into: &serializationContext)
      try flagField1.serialize(into: &serializationContext)
      serializationContext.serialize(int64: correctionField)
      serializationContext.serialize([
        messageTypeSpecific.0,
        messageTypeSpecific.1,
        messageTypeSpecific.2,
        messageTypeSpecific.3,
      ])
      try sourcePortIdentity.serialize(into: &serializationContext)
      serializationContext.serialize(uint16: sequenceId)
      try controlField.serialize(into: &serializationContext)
      serializationContext.serialize(uint8: logMessageInterval)
    }

    public init(parsing input: inout ParserSpan) throws {
      majorSdoId_messageType = try UInt8(parsing: &input)
      guard MessageType(rawValue: majorSdoId_messageType & Self.MessageTypeMask) != nil else {
        throw Error.unknownMessageType
      }
      versionPTP = try PtpVersion(parsing: &input)
      messageLength = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      // messageLength includes the entire message including the 4 bytes we've already parsed
      // input.count is now original_buffer_size - 4, so we need to add 4 back
      guard messageLength <= input.count + 4 else {
        throw Error.messageTruncated
      }
      domainNumber = try UInt8(parsing: &input)
      minorSdoId = try UInt8(parsing: &input)
      flagField0 = try FlagField0(parsing: &input)
      flagField1 = try FlagField1(parsing: &input)
      correctionField = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
      let bytes = try Array(parsing: &input, byteCount: 4)
      messageTypeSpecific = (bytes[0], bytes[1], bytes[2], bytes[3])
      sourcePortIdentity = try PortIdentity(parsing: &input)
      sequenceId = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      controlField = try ControlField(parsing: &input)
      logMessageInterval = try UInt8(parsing: &input)
    }
  }

  public enum TimeSource: UInt8 {
    case atomicClock = 0x10
    case gps = 0x20
    case terrestialRadio = 0x30
    case ptp = 0x40
    case ntp = 0x50
    case handSet = 0x60
    case other = 0x90
    case internalOscillator = 0xA0
  }

  public enum ActionField: UInt8, SerDes, Sendable {
    case get = 0
    case set = 1
    case response = 2
    case command = 3
    case acknowledge = 4

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw Error.unknownEnumerationValue
      }
      self = value
    }
  }

  struct ManagementMessage: Sendable, SerDes {
    static let Size = Header.Size + 14 // excluding PTPManagementTLV

    let header: Header
    let targetPortIdentity: PortIdentity
    let startingBoundaryHops: UInt8
    let boundaryHops: UInt8
    let reserved_actionField: UInt8
    let reserved: UInt8
    let managementTLV: PTPManagementTLV

    var actionField: ActionField {
      ActionField(rawValue: reserved_actionField & 0x1F)!
    }

    init(
      header: Header,
      targetPortIdentity: PortIdentity,
      startingBoundaryHops: UInt8,
      boundaryHops: UInt8,
      reserved_actionField: UInt8,
      reserved: UInt8,
      managementTLV: PTPManagementTLV
    ) {
      self.header = header
      self.targetPortIdentity = targetPortIdentity
      self.startingBoundaryHops = startingBoundaryHops
      self.boundaryHops = boundaryHops
      self.reserved_actionField = reserved_actionField
      self.reserved = reserved
      self.managementTLV = managementTLV
    }

    init(
      header: Header,
      targetPortIdentity: PortIdentity,
      startingBoundaryHops: UInt8,
      boundaryHops: UInt8,
      actionField: ActionField,
      managementTLV: PTPManagementTLV
    ) {
      self.header = header
      self.targetPortIdentity = targetPortIdentity
      self.startingBoundaryHops = startingBoundaryHops
      self.boundaryHops = boundaryHops
      reserved_actionField = actionField.rawValue
      reserved = 0
      self.managementTLV = managementTLV
    }

    func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      try header.serialize(into: &serializationContext)
      try targetPortIdentity.serialize(into: &serializationContext)
      serializationContext.serialize(uint8: startingBoundaryHops)
      serializationContext.serialize(uint8: boundaryHops)
      serializationContext.serialize(uint8: reserved_actionField)
      serializationContext.serialize(uint8: reserved)
      try managementTLV.serialize(into: &serializationContext)
    }

    init(parsing input: inout ParserSpan) throws {
      header = try Header(parsing: &input)
      targetPortIdentity = try PortIdentity(parsing: &input)
      startingBoundaryHops = try UInt8(parsing: &input)
      boundaryHops = try UInt8(parsing: &input)
      reserved_actionField = try UInt8(parsing: &input)
      guard ActionField(rawValue: reserved_actionField) != nil else {
        throw Error.invalidManagementActionField
      }
      reserved = try UInt8(parsing: &input)

      // Parse TLV type to determine which TLV struct to use
      let tlvTypeRaw = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
      guard let tlvType = TLVType(rawValue: tlvTypeRaw) else {
        throw Error.unknownTLVType
      }

      // Now parse the length field
      let lengthField = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)

      switch tlvType {
      case .management:
        // Parse management ID and data
        guard lengthField >= 2 else {
          throw Error.invalidManagementTLVLength
        }
        // Parse raw management ID first, then consume data field even if ID is unknown
        let managementIdRaw = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
        let dataField = try Array(parsing: &input, byteCount: Int(lengthField - 2))
        // Now validate the management ID after consuming all data
        guard let managementId = PTPManagementID(rawValue: managementIdRaw) else {
          throw Error.unknownEnumerationValue
        }
        managementTLV = PTPManagementTLV(
          _tlvType: tlvType,
          _managementId: managementId,
          _dataField: dataField
        )
      case .managementErrorStatus:
        // Parse error status TLV and throw its error
        guard lengthField >= 8 else {
          throw Error.invalidManagementTLVLength
        }
        let managementErrorId = try PTPManagementError(parsing: &input)
        // Consume the rest of the TLV before throwing
        _ = try PTPManagementID(parsing: &input) // managementId
        _ = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self) // reserved
        _ = try Array(parsing: &input, byteCount: Int(lengthField - 8)) // displayData
        throw managementErrorId
      default:
        throw Error.invalidManagementTLVType
      }
    }
  }
}
