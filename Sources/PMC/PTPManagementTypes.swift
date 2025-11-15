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

public enum PTPManagementError: UInt16, Error, SerDes, Sendable {
  case noError = 0
  case responseTooBig = 1
  case noSuchId = 2
  case wrongLength = 3
  case wrongValue = 4
  case notSetable = 5
  case notSupported = 6
  case unpopulated = 7
  case generalError = 0xFFFE
  case reserved = 0xFFFF

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint16: rawValue)
  }

  public init(parsing input: inout ParserSpan) throws {
    let rawValue = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    guard let value = Self(rawValue: rawValue) else {
      throw PTP.Error.unknownEnumerationValue
    }
    self = value
  }
}

enum PTPManagementID: UInt16, SerDes, Sendable {
  case NULL_PTP_MANAGEMENT = 0
  case CLOCK_DESCRIPTION = 1
  case USER_DESCRIPTION = 2
  case SAVE_IN_NON_VOLATILE_STORAGE = 3
  case RESET_NON_VOLATILE_STORAGE = 4
  case INITIALIZE = 5
  case FAULT_LOG = 6
  case FAULT_LOG_RESET = 7
  case DEFAULT_DATA_SET = 0x2000
  case CURRENT_DATA_SET = 0x2001
  case PARENT_DATA_SET = 0x2002
  case TIME_PROPERTIES_DATA_SET = 0x2003
  case PORT_DATA_SET = 0x2004
  case PRIORITY1 = 0x2005
  case PRIORITY2 = 0x2006
  case DOMAIN = 0x2007
  case SLAVE_ONLY = 0x2008
  case LOG_ANNOUNCE_INTERVAL = 0x2009
  case ANNOUNCE_RECEIPT_TIMEOUT = 0x200A
  case LOG_SYNC_INTERVAL = 0x200B
  case VERSION_NUMBER = 0x200C
  case ENABLE_PORT = 0x200D
  case DISABLE_PORT = 0x200E
  case TIME = 0x200F
  case CLOCK_ACCURACY = 0x2010
  case UTC_PROPERTIES = 0x2011
  case TRACEABILITY_PROPERTIES = 0x2012
  case TIMESCALE_PROPERTIES = 0x2013
  case UNICAST_NEGOTIATION_ENABLE = 0x2014
  case PATH_TRACE_LIST = 0x2015
  case PATH_TRACE_ENABLE = 0x2016
  case GRANDMASTER_CLUSTER_TABLE = 0x2017
  case UNICAST_MASTER_TABLE = 0x2018
  case UNICAST_MASTER_MAX_TABLE_SIZE = 0x2019
  case ACCEPTABLE_MASTER_TABLE = 0x201A
  case ACCEPTABLE_MASTER_TABLE_ENABLED = 0x201B
  case ACCEPTABLE_MASTER_MAX_TABLE_SIZE = 0x201C
  case ALTERNATE_MASTER = 0x201D
  case ALTERNATE_TIME_OFFSET_ENABLE = 0x201E
  case ALTERNATE_TIME_OFFSET_NAME = 0x201F
  case ALTERNATE_TIME_OFFSET_MAX_KEY = 0x2020
  case ALTERNATE_TIME_OFFSET_PROPERTIES = 0x2021
  case EXTERNAL_PORT_CONFIGURATION_ENABLED = 0x3000
  case MASTER_ONLY = 0x3001
  case HOLDOVER_UPGRADE_ENABLE = 0x3002
  case EXT_PORT_CONFIG_PORT_DATA_SET = 0x3003
  case TRANSPARENT_CLOCK_DEFAULT_DATA_SET = 0x4000
  case TRANSPARENT_CLOCK_PORT_DATA_SET = 0x4001
  case PRIMARY_DOMAIN = 0x4002
  case DELAY_MECHANISM = 0x6000
  case LOG_MIN_PDELAY_REQ_INTERVAL = 0x6001
  case PORT_DATA_SET_NP = 0xC002
  case PORT_PROPERTIES_NP = 0xC004
  case PORT_STATS_NP = 0xC005
  case PORT_SERVICE_STATS_NP = 0xC007
  case UNICAST_MASTER_TABLE_NP = 0xC008
  case PORT_HWCLOCK_NP = 0xC009
  case POWER_PROFILE_SETTINGS_NP = 0xC00A
  case CMLDS_INFO_NP = 0xC00B

  func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint16: rawValue)
  }

  init(parsing input: inout ParserSpan) throws {
    let rawValue = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    guard let value = Self(rawValue: rawValue) else {
      throw PTP.Error.unknownEnumerationValue
    }
    self = value
  }
}

struct PTPManagementTLV: SerDes, Sendable {
  private let tlvType: PTP.TLVType
  private let lengthField: UInt16
  private let managementId: PTPManagementID
  private let dataField: [UInt8]

  private init(tlvType: PTP.TLVType, managementId: PTPManagementID, dataField: [UInt8]) {
    self.tlvType = tlvType
    lengthField = 0
    self.managementId = managementId
    self.dataField = dataField
  }

  // Internal initializer for parsing with pre-parsed fields
  init(_tlvType: PTP.TLVType, _managementId: PTPManagementID, _dataField: [UInt8]) {
    tlvType = _tlvType
    lengthField = UInt16(_dataField.count + 2)
    managementId = _managementId
    dataField = _dataField
  }

  // for GET, COMMAND requests that do not have any associated data
  init(managementId: PTPManagementID) {
    self.init(tlvType: .management, managementId: managementId, dataField: [])
  }

  init(_ data: PTPManagementRepresentable) throws {
    let managementId = type(of: data).managementId
    try self.init(tlvType: .management, managementId: managementId, dataField: data.serialized())
  }

  func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try tlvType.serialize(into: &serializationContext)
    serializationContext.serialize(uint16: UInt16(dataField.count + 2))
    try managementId.serialize(into: &serializationContext)
    serializationContext.serialize(dataField)
  }

  init(parsing input: inout ParserSpan) throws {
    tlvType = try PTP.TLVType(parsing: &input)
    let lengthField = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    guard lengthField >= 2 else {
      throw PTP.Error.invalidManagementTLVLength
    }
    self.lengthField = lengthField
    managementId = try PTPManagementID(parsing: &input)
    dataField = try Array(parsing: &input, byteCount: Int(lengthField - 2))
  }

  var size: Int {
    2 + 2 + 2 + dataField.count
  }

  var data: PTPManagementRepresentable {
    get throws {
      try dataField.withParserSpan { input in
        switch managementId {
        case .NULL_PTP_MANAGEMENT:
          return try Null(parsing: &input)
        case .TIME:
          return try Time(parsing: &input)
        case .PRIORITY1:
          return try Priority1(parsing: &input)
        case .PRIORITY2:
          return try Priority2(parsing: &input)
        case .CLOCK_ACCURACY:
          return try ClockAccuracy(parsing: &input)
        case .DEFAULT_DATA_SET:
          return try DefaultDataSet(parsing: &input)
        case .PORT_DATA_SET:
          return try PortDataSet(parsing: &input)
        case .PORT_DATA_SET_NP:
          return try PortDataSetNP(parsing: &input)
        case .PORT_PROPERTIES_NP:
          return try PortPropertiesNP(parsing: &input)
        default:
          throw PTP.Error.unsupportedManagementID
        }
      }
    }
  }
}

struct PTPManagementErrorStatusTLV: SerDes, Sendable {
  private let tlvType: PTP.TLVType
  private let lengthField: UInt16
  let managementErrorId: PTPManagementError
  private let managementId: PTPManagementID
  private let reserved: UInt32
  private let displayData: [UInt8]

  func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try tlvType.serialize(into: &serializationContext)
    serializationContext.serialize(uint16: UInt16(8 + displayData.count))
    try managementErrorId.serialize(into: &serializationContext)
    try managementId.serialize(into: &serializationContext)
    serializationContext.serialize(uint32: reserved)
    serializationContext.serialize(displayData)
    // TODO: padding
  }

  init(parsing input: inout ParserSpan) throws {
    tlvType = try PTP.TLVType(parsing: &input)
    let lengthField = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    guard lengthField >= 8 else {
      throw PTP.Error.invalidManagementTLVLength
    }
    self.lengthField = lengthField
    managementErrorId = try PTPManagementError(parsing: &input)
    managementId = try PTPManagementID(parsing: &input)
    reserved = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
    displayData = try Array(parsing: &input, byteCount: Int(lengthField - 8))
  }

  var size: Int {
    2 + 2 + 8 + displayData.count
  }
}

protocol PTPManagementRepresentable: SerDes & Sendable {
  static var managementId: PTPManagementID { get }
}

public struct Null: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .NULL_PTP_MANAGEMENT }

  init() {}

  public func serialize(into: inout IEEE802.SerializationContext) throws {}

  public init(parsing input: inout ParserSpan) throws {}
}

public struct DefaultDataSet: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .DEFAULT_DATA_SET }

  public struct Flags: OptionSet, Sendable {
    public typealias RawValue = UInt8

    public let rawValue: RawValue

    public init(rawValue: RawValue) { self.rawValue = rawValue }

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      rawValue = try UInt8(parsing: &input)
    }

    public static let twoStepFlag = Flags(rawValue: 1 << 0)
    public static let slaveOnly = Flags(rawValue: 1 << 0)
  }

  public let flags: Flags
  private let reserved1: UInt8
  public let numberPorts: UInt16
  public let priority1: UInt8
  public let clockQuality: PTP.ClockQuality
  public let priority2: UInt8
  public let clockIdentity: PTP.ClockIdentity
  public let domainNumber: UInt8
  private let reserved2: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try flags.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: reserved1)
    serializationContext.serialize(uint16: numberPorts)
    serializationContext.serialize(uint8: priority1)
    try clockQuality.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: priority2)
    try clockIdentity.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: domainNumber)
    serializationContext.serialize(uint8: reserved2)
  }

  public init(parsing input: inout ParserSpan) throws {
    flags = try Flags(parsing: &input)
    reserved1 = try UInt8(parsing: &input)
    numberPorts = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    priority1 = try UInt8(parsing: &input)
    clockQuality = try PTP.ClockQuality(parsing: &input)
    priority2 = try UInt8(parsing: &input)
    clockIdentity = try PTP.ClockIdentity(parsing: &input)
    domainNumber = try UInt8(parsing: &input)
    reserved2 = try UInt8(parsing: &input)
  }
}

public struct Time: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .TIME }

  public let timestamp: PTP.Timestamp

  init(timestamp: PTP.Timestamp) { self.timestamp = timestamp }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try timestamp.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    timestamp = try PTP.Timestamp(parsing: &input)
  }
}

public struct ClockAccuracy: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .CLOCK_ACCURACY }

  public let clockAccuracy: UInt8
  public let reserved: UInt8

  init(clockAccuracy: UInt8) {
    self.clockAccuracy = clockAccuracy
    reserved = 0
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: clockAccuracy)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    clockAccuracy = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct Priority1: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PRIORITY1 }

  public let priority1: UInt8
  public let reserved: UInt8

  init(priority1: UInt8) {
    self.priority1 = priority1
    reserved = 0
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: priority1)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    priority1 = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct Priority2: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PRIORITY2 }

  public let priority2: UInt8
  public let reserved: UInt8

  init(priority2: UInt8) {
    self.priority2 = priority2
    reserved = 0
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: priority2)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    priority2 = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct PortDataSet: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PORT_DATA_SET }

  public let portIdentity: PTP.PortIdentity
  public let portState: PTP.PortState
  public let logMinDelayReqInterval: Int8
  public let meanLinkDelay: PTP.TimeInterval
  public let logAnnounceInterval: Int8
  public let announceReceiptTimeout: UInt8
  public let logSyncInterval: Int8
  public let delayMechanism: PTP.DelayMechanism
  public let logMinPdelayReqInterval: Int8
  public let reserved_versionNumber: UInt8

  init(
    portIdentity: PTP.PortIdentity,
    portState: PTP.PortState,
    logMinDelayReqInterval: Int8,
    meanLinkDelay: PTP.TimeInterval,
    logAnnounceInterval: Int8,
    announceReceiptTimeout: UInt8,
    logSyncInterval: Int8,
    delayMechanism: PTP.DelayMechanism,
    logMinPdelayReqInterval: Int8,
    reserved_versionNumber: UInt8
  ) {
    self.portIdentity = portIdentity
    self.portState = portState
    self.logMinDelayReqInterval = logMinDelayReqInterval
    self.meanLinkDelay = meanLinkDelay
    self.logAnnounceInterval = logAnnounceInterval
    self.announceReceiptTimeout = announceReceiptTimeout
    self.logSyncInterval = logSyncInterval
    self.delayMechanism = delayMechanism
    self.logMinPdelayReqInterval = logMinPdelayReqInterval
    self.reserved_versionNumber = reserved_versionNumber
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try portIdentity.serialize(into: &serializationContext)
    try portState.serialize(into: &serializationContext)
    serializationContext.serialize(int8: logMinDelayReqInterval)
    serializationContext.serialize(int64: meanLinkDelay)
    serializationContext.serialize(int8: logAnnounceInterval)
    serializationContext.serialize(uint8: announceReceiptTimeout)
    serializationContext.serialize(int8: logSyncInterval)
    try delayMechanism.serialize(into: &serializationContext)
    serializationContext.serialize(int8: logMinPdelayReqInterval)
    serializationContext.serialize(uint8: reserved_versionNumber)
  }

  public init(parsing input: inout ParserSpan) throws {
    portIdentity = try PTP.PortIdentity(parsing: &input)
    portState = try PTP.PortState(parsing: &input)
    logMinDelayReqInterval = try Int8(parsing: &input)
    meanLinkDelay = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
    logAnnounceInterval = try Int8(parsing: &input)
    announceReceiptTimeout = try UInt8(parsing: &input)
    logSyncInterval = try Int8(parsing: &input)
    delayMechanism = try PTP.DelayMechanism(parsing: &input)
    logMinPdelayReqInterval = try Int8(parsing: &input)
    reserved_versionNumber = try UInt8(parsing: &input)
  }

  public var versionNumber: UInt8 {
    reserved_versionNumber & 0x0F
  }
}

public struct PortPropertiesNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PORT_PROPERTIES_NP }

  public enum Timestamping: UInt8, SerDes, Sendable {
    case software = 0
    case hardware = 1
    case legacyHW = 2
    case oneStep = 3
    case p2pOneStep = 4

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      serializationContext.serialize(uint8: rawValue)
    }

    public init(parsing input: inout ParserSpan) throws {
      let rawValue = try UInt8(parsing: &input)
      guard let value = Self(rawValue: rawValue) else {
        throw PTP.Error.unknownEnumerationValue
      }
      self = value
    }
  }

  public let portIdentity: PTP.PortIdentity
  public let portState: PTP.PortState
  public let timestamping: Timestamping
  public let interface: PTP.PTPText

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try portIdentity.serialize(into: &serializationContext)
    try portState.serialize(into: &serializationContext)
    try timestamping.serialize(into: &serializationContext)
    try interface.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    portIdentity = try PTP.PortIdentity(parsing: &input)
    portState = try PTP.PortState(parsing: &input)
    timestamping = try Timestamping(parsing: &input)
    interface = try PTP.PTPText(parsing: &input)
  }
}

public struct PortDataSetNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PORT_DATA_SET_NP }

  public let neighborPropDelayThresh: UInt32
  public let asCapable: Int32

  init(
    neighborPropDelayThresh: UInt32,
    asCapable: Int32
  ) {
    self.neighborPropDelayThresh = neighborPropDelayThresh
    self.asCapable = asCapable
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint32: neighborPropDelayThresh)
    serializationContext.serialize(int32: asCapable)
  }

  public init(parsing input: inout ParserSpan) throws {
    neighborPropDelayThresh = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
    asCapable = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
  }
}
