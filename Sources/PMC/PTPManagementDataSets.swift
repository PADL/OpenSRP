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

// IEEE 1588-2019 clause 15.5.3 standard management data sets.

public struct ClockDescription: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .CLOCK_DESCRIPTION }

  public static let ManufacturerIdentityLength = 3
  public static let ProfileIdentityLength = 6

  public let clockType: UInt16
  public let physicalLayerProtocol: PTP.PTPText
  public let physicalAddress: PTP.PhysicalAddress
  public let protocolAddress: PTP.PortAddress
  public let manufacturerIdentity: [UInt8]
  private let reserved: UInt8
  public let productDescription: PTP.PTPText
  public let revisionData: PTP.PTPText
  public let userDescription: PTP.PTPText
  public let profileIdentity: [UInt8]

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint16: clockType)
    try physicalLayerProtocol.serialize(into: &serializationContext)
    try physicalAddress.serialize(into: &serializationContext)
    try protocolAddress.serialize(into: &serializationContext)
    serializationContext.serialize(manufacturerIdentity)
    serializationContext.serialize(uint8: reserved)
    try productDescription.serialize(into: &serializationContext)
    try revisionData.serialize(into: &serializationContext)
    try userDescription.serialize(into: &serializationContext)
    serializationContext.serialize(profileIdentity)
  }

  public init(parsing input: inout ParserSpan) throws {
    clockType = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    physicalLayerProtocol = try PTP.PTPText(parsing: &input)
    physicalAddress = try PTP.PhysicalAddress(parsing: &input)
    protocolAddress = try PTP.PortAddress(parsing: &input)
    manufacturerIdentity = try Array(parsing: &input, byteCount: Self.ManufacturerIdentityLength)
    reserved = try UInt8(parsing: &input)
    productDescription = try PTP.PTPText(parsing: &input)
    revisionData = try PTP.PTPText(parsing: &input)
    userDescription = try PTP.PTPText(parsing: &input)
    profileIdentity = try Array(parsing: &input, byteCount: Self.ProfileIdentityLength)
  }
}

public struct UserDescription: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .USER_DESCRIPTION }

  public let userDescription: PTP.PTPText

  init(userDescription: PTP.PTPText) { self.userDescription = userDescription }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try userDescription.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    userDescription = try PTP.PTPText(parsing: &input)
  }
}

public struct CurrentDataSet: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .CURRENT_DATA_SET }

  public let stepsRemoved: UInt16
  public let offsetFromMaster: PTP.TimeInterval
  public let meanPathDelay: PTP.TimeInterval

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint16: stepsRemoved)
    serializationContext.serialize(int64: offsetFromMaster)
    serializationContext.serialize(int64: meanPathDelay)
  }

  public init(parsing input: inout ParserSpan) throws {
    stepsRemoved = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    offsetFromMaster = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
    meanPathDelay = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
  }
}

public struct ParentDataSet: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PARENT_DATA_SET }

  public let parentPortIdentity: PTP.PortIdentity
  public let parentStats: UInt8
  private let reserved: UInt8
  public let observedParentOffsetScaledLogVariance: UInt16
  public let observedParentClockPhaseChangeRate: Int32
  public let grandmasterPriority1: UInt8
  public let grandmasterClockQuality: PTP.ClockQuality
  public let grandmasterPriority2: UInt8
  public let grandmasterIdentity: PTP.ClockIdentity

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try parentPortIdentity.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: parentStats)
    serializationContext.serialize(uint8: reserved)
    serializationContext.serialize(uint16: observedParentOffsetScaledLogVariance)
    serializationContext.serialize(int32: observedParentClockPhaseChangeRate)
    serializationContext.serialize(uint8: grandmasterPriority1)
    try grandmasterClockQuality.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: grandmasterPriority2)
    try grandmasterIdentity.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    parentPortIdentity = try PTP.PortIdentity(parsing: &input)
    parentStats = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
    observedParentOffsetScaledLogVariance = try UInt16(
      parsing: &input,
      storedAsBigEndian: UInt16.self
    )
    observedParentClockPhaseChangeRate = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    grandmasterPriority1 = try UInt8(parsing: &input)
    grandmasterClockQuality = try PTP.ClockQuality(parsing: &input)
    grandmasterPriority2 = try UInt8(parsing: &input)
    grandmasterIdentity = try PTP.ClockIdentity(parsing: &input)
  }
}

public struct TimePropertiesDataSet: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .TIME_PROPERTIES_DATA_SET }

  // flagField[1] of the announce message, clause 13.3.2.7
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

    public static let leap61 = Flags(rawValue: 1 << 0)
    public static let leap59 = Flags(rawValue: 1 << 1)
    public static let currentUtcOffsetValid = Flags(rawValue: 1 << 2)
    public static let ptpTimescale = Flags(rawValue: 1 << 3)
    public static let timeTraceable = Flags(rawValue: 1 << 4)
    public static let frequencyTraceable = Flags(rawValue: 1 << 5)
  }

  public let currentUtcOffset: Int16
  public let flags: Flags
  public let timeSource: PTP.TimeSource

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(int16: currentUtcOffset)
    try flags.serialize(into: &serializationContext)
    try timeSource.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    currentUtcOffset = try Int16(parsing: &input, storedAsBigEndian: Int16.self)
    flags = try Flags(parsing: &input)
    timeSource = try PTP.TimeSource(parsing: &input)
  }
}

public struct Domain: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .DOMAIN }

  public let domainNumber: UInt8
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: domainNumber)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    domainNumber = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct SlaveOnly: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .SLAVE_ONLY }

  public let slaveOnly: Bool
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: slaveOnly ? 1 : 0)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    slaveOnly = try UInt8(parsing: &input) & 1 != 0
    reserved = try UInt8(parsing: &input)
  }
}

public struct LogAnnounceInterval: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .LOG_ANNOUNCE_INTERVAL }

  public let logAnnounceInterval: Int8
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(int8: logAnnounceInterval)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    logAnnounceInterval = try Int8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct AnnounceReceiptTimeout: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .ANNOUNCE_RECEIPT_TIMEOUT }

  public let announceReceiptTimeout: UInt8
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: announceReceiptTimeout)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    announceReceiptTimeout = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct LogSyncInterval: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .LOG_SYNC_INTERVAL }

  public let logSyncInterval: Int8
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(int8: logSyncInterval)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    logSyncInterval = try Int8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct VersionNumber: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .VERSION_NUMBER }

  public let versionNumber: UInt8
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: versionNumber)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    versionNumber = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct EnablePort: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .ENABLE_PORT }

  init() {}

  public func serialize(into: inout IEEE802.SerializationContext) throws {}

  public init(parsing input: inout ParserSpan) throws {}
}

public struct DisablePort: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .DISABLE_PORT }

  init() {}

  public func serialize(into: inout IEEE802.SerializationContext) throws {}

  public init(parsing input: inout ParserSpan) throws {}
}

public struct TraceabilityProperties: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .TRACEABILITY_PROPERTIES }

  public let flags: TimePropertiesDataSet.Flags
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try flags.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    flags = try TimePropertiesDataSet.Flags(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct TimescaleProperties: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .TIMESCALE_PROPERTIES }

  public let flags: TimePropertiesDataSet.Flags
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try flags.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    flags = try TimePropertiesDataSet.Flags(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct AlternateTimeOffsetEnable: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .ALTERNATE_TIME_OFFSET_ENABLE }

  // a keyField of 0xFF enables or disables all alternate time offsets
  public let keyField: UInt8
  public let enabled: Bool

  init(keyField: UInt8, enabled: Bool) {
    self.keyField = keyField
    self.enabled = enabled
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: keyField)
    serializationContext.serialize(uint8: enabled ? 1 : 0)
  }

  public init(parsing input: inout ParserSpan) throws {
    keyField = try UInt8(parsing: &input)
    enabled = try UInt8(parsing: &input) & 1 != 0
  }
}

public struct AlternateTimeOffsetName: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .ALTERNATE_TIME_OFFSET_NAME }

  public let keyField: UInt8
  public let displayName: PTP.PTPText

  init(keyField: UInt8, displayName: PTP.PTPText) {
    self.keyField = keyField
    self.displayName = displayName
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: keyField)
    try displayName.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    keyField = try UInt8(parsing: &input)
    displayName = try PTP.PTPText(parsing: &input)
  }
}

public struct AlternateTimeOffsetMaxKey: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .ALTERNATE_TIME_OFFSET_MAX_KEY }

  public let maxKey: UInt8
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: maxKey)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    maxKey = try UInt8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct AlternateTimeOffsetProperties: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .ALTERNATE_TIME_OFFSET_PROPERTIES }

  public let keyField: UInt8
  public let currentOffset: Int32
  public let jumpSeconds: Int32
  // carried on the wire as a 16-bit MSB and a 32-bit LSB half
  public let timeOfNextJump: UInt64
  private let pad: UInt8

  init(
    keyField: UInt8,
    currentOffset: Int32,
    jumpSeconds: Int32,
    timeOfNextJump: UInt64
  ) {
    self.keyField = keyField
    self.currentOffset = currentOffset
    self.jumpSeconds = jumpSeconds
    self.timeOfNextJump = timeOfNextJump
    pad = 0
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: keyField)
    serializationContext.serialize(int32: currentOffset)
    serializationContext.serialize(int32: jumpSeconds)
    serializationContext.serialize(uint16: UInt16(truncatingIfNeeded: timeOfNextJump >> 32))
    serializationContext.serialize(uint32: UInt32(truncatingIfNeeded: timeOfNextJump))
    serializationContext.serialize(uint8: pad)
  }

  public init(parsing input: inout ParserSpan) throws {
    keyField = try UInt8(parsing: &input)
    currentOffset = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    jumpSeconds = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    let secondsMsb = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    let secondsLsb = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
    timeOfNextJump = UInt64(secondsMsb) << 32 | UInt64(secondsLsb)
    pad = try UInt8(parsing: &input)
  }
}

public struct MasterOnly: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .MASTER_ONLY }

  public let masterOnly: Bool
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint8: masterOnly ? 1 : 0)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    masterOnly = try UInt8(parsing: &input) & 1 != 0
    reserved = try UInt8(parsing: &input)
  }
}

public struct DelayMechanism: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .DELAY_MECHANISM }

  public let delayMechanism: PTP.DelayMechanism
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try delayMechanism.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    delayMechanism = try PTP.DelayMechanism(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct LogMinPdelayReqInterval: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .LOG_MIN_PDELAY_REQ_INTERVAL }

  public let logMinPdelayReqInterval: Int8
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(int8: logMinPdelayReqInterval)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    logMinPdelayReqInterval = try Int8(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}
