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

// Non-portable (implementation specific) management IDs defined by linuxptp.

// linuxptp encodes the 64-bit statistics counters in little-endian byte order.
private func _serialize(
  le64: UInt64,
  into serializationContext: inout IEEE802.SerializationContext
) {
  serializationContext.serialize(uint64: le64.byteSwapped)
}

private func _parseLE64(_ input: inout ParserSpan, count: Int) throws -> [UInt64] {
  try (0..<count).map { _ in try UInt64(parsing: &input, storedAsLittleEndian: UInt64.self) }
}

public struct TimeStatusNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .TIME_STATUS_NP }

  public let masterOffset: Int64 // nanoseconds
  public let ingressTime: Int64 // nanoseconds
  public let cumulativeScaledRateOffset: Int32
  public let scaledLastGmPhaseChange: Int32
  public let gmTimeBaseIndicator: UInt16
  public let lastGmPhaseChange: PTP.ScaledNs
  public let gmPresent: Int32
  public let gmIdentity: PTP.ClockIdentity

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(int64: masterOffset)
    serializationContext.serialize(int64: ingressTime)
    serializationContext.serialize(int32: cumulativeScaledRateOffset)
    serializationContext.serialize(int32: scaledLastGmPhaseChange)
    serializationContext.serialize(uint16: gmTimeBaseIndicator)
    try lastGmPhaseChange.serialize(into: &serializationContext)
    serializationContext.serialize(int32: gmPresent)
    try gmIdentity.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    masterOffset = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
    ingressTime = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
    cumulativeScaledRateOffset = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    scaledLastGmPhaseChange = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    gmTimeBaseIndicator = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    lastGmPhaseChange = try PTP.ScaledNs(parsing: &input)
    gmPresent = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    gmIdentity = try PTP.ClockIdentity(parsing: &input)
  }
}

public struct GrandmasterSettingsNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .GRANDMASTER_SETTINGS_NP }

  public let clockQuality: PTP.ClockQuality
  public let currentUtcOffset: Int16
  public let timeFlags: TimePropertiesDataSet.Flags
  public let timeSource: PTP.TimeSource

  init(
    clockQuality: PTP.ClockQuality,
    currentUtcOffset: Int16,
    timeFlags: TimePropertiesDataSet.Flags,
    timeSource: PTP.TimeSource
  ) {
    self.clockQuality = clockQuality
    self.currentUtcOffset = currentUtcOffset
    self.timeFlags = timeFlags
    self.timeSource = timeSource
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try clockQuality.serialize(into: &serializationContext)
    serializationContext.serialize(int16: currentUtcOffset)
    try timeFlags.serialize(into: &serializationContext)
    try timeSource.serialize(into: &serializationContext)
  }

  public init(parsing input: inout ParserSpan) throws {
    clockQuality = try PTP.ClockQuality(parsing: &input)
    currentUtcOffset = try Int16(parsing: &input, storedAsBigEndian: Int16.self)
    timeFlags = try TimePropertiesDataSet.Flags(parsing: &input)
    timeSource = try PTP.TimeSource(parsing: &input)
  }
}

public struct SubscribeEventsNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .SUBSCRIBE_EVENTS_NP }

  public static let EventBitmaskCount = 64

  public enum Event: Int, CaseIterable, Sendable {
    case portState = 0
    case timeSync = 1
    case parentDataSet = 2
    case cmlds = 3
  }

  public let duration: UInt16 // seconds
  private let bitmask: [UInt8]

  public func isSubscribed(to event: Event) -> Bool {
    bitmask[event.rawValue / 8] & UInt8(1 << (event.rawValue % 8)) != 0
  }

  public var events: [Event] {
    Event.allCases.filter { isSubscribed(to: $0) }
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(uint16: duration)
    serializationContext.serialize(bitmask)
  }

  public init(parsing input: inout ParserSpan) throws {
    duration = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    bitmask = try Array(parsing: &input, byteCount: Self.EventBitmaskCount)
  }
}

public struct SynchronizationUncertainNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .SYNCHRONIZATION_UNCERTAIN_NP }

  public enum Uncertain: UInt8, SerDes, Sendable {
    case `false` = 0
    case `true` = 1
    case dontCare = 0xFF

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

  public let uncertain: Uncertain
  private let reserved: UInt8

  init(uncertain: Uncertain) {
    self.uncertain = uncertain
    reserved = 0
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try uncertain.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    uncertain = try Uncertain(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct ExternalGrandmasterPropertiesNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .EXTERNAL_GRANDMASTER_PROPERTIES_NP }

  public let gmIdentity: PTP.ClockIdentity
  public let stepsRemoved: UInt16

  init(gmIdentity: PTP.ClockIdentity, stepsRemoved: UInt16) {
    self.gmIdentity = gmIdentity
    self.stepsRemoved = stepsRemoved
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try gmIdentity.serialize(into: &serializationContext)
    serializationContext.serialize(uint16: stepsRemoved)
  }

  public init(parsing input: inout ParserSpan) throws {
    gmIdentity = try PTP.ClockIdentity(parsing: &input)
    stepsRemoved = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
  }
}

public struct PortStatsNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PORT_STATS_NP }

  // four bits are dedicated to the messageType field
  public static let MaxMessageTypes = 16

  public let portIdentity: PTP.PortIdentity
  public let rxMsgType: [UInt64]
  public let txMsgType: [UInt64]

  public subscript(rx messageType: PTP.MessageType) -> UInt64 {
    rxMsgType[Int(messageType.rawValue)]
  }

  public subscript(tx messageType: PTP.MessageType) -> UInt64 {
    txMsgType[Int(messageType.rawValue)]
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try portIdentity.serialize(into: &serializationContext)
    for count in rxMsgType {
      _serialize(le64: count, into: &serializationContext)
    }
    for count in txMsgType {
      _serialize(le64: count, into: &serializationContext)
    }
  }

  public init(parsing input: inout ParserSpan) throws {
    portIdentity = try PTP.PortIdentity(parsing: &input)
    rxMsgType = try _parseLE64(&input, count: Self.MaxMessageTypes)
    txMsgType = try _parseLE64(&input, count: Self.MaxMessageTypes)
  }
}

public struct PortServiceStatsNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PORT_SERVICE_STATS_NP }

  public let portIdentity: PTP.PortIdentity
  public let announceTimeout: UInt64
  public let syncTimeout: UInt64
  public let delayTimeout: UInt64
  public let unicastServiceTimeout: UInt64
  public let unicastRequestTimeout: UInt64
  public let masterAnnounceTimeout: UInt64
  public let masterSyncTimeout: UInt64
  public let qualificationTimeout: UInt64
  public let syncMismatch: UInt64
  public let followUpMismatch: UInt64

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try portIdentity.serialize(into: &serializationContext)
    for count in [
      announceTimeout,
      syncTimeout,
      delayTimeout,
      unicastServiceTimeout,
      unicastRequestTimeout,
      masterAnnounceTimeout,
      masterSyncTimeout,
      qualificationTimeout,
      syncMismatch,
      followUpMismatch,
    ] {
      _serialize(le64: count, into: &serializationContext)
    }
  }

  public init(parsing input: inout ParserSpan) throws {
    portIdentity = try PTP.PortIdentity(parsing: &input)
    let stats = try _parseLE64(&input, count: 10)
    announceTimeout = stats[0]
    syncTimeout = stats[1]
    delayTimeout = stats[2]
    unicastServiceTimeout = stats[3]
    unicastRequestTimeout = stats[4]
    masterAnnounceTimeout = stats[5]
    masterSyncTimeout = stats[6]
    qualificationTimeout = stats[7]
    syncMismatch = stats[8]
    followUpMismatch = stats[9]
  }
}

public struct UnicastMasterTableNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .UNICAST_MASTER_TABLE_NP }

  // the entry state is the unicast client FSM state, not a PTP port state
  public enum State: UInt8, SerDes, Sendable {
    case wait = 0
    case haveAnnounce = 1
    case needSyncDelayResponse = 2
    case haveSyncDelayResponse = 3

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

  public struct Entry: SerDes, Sendable {
    public let portIdentity: PTP.PortIdentity
    public let clockQuality: PTP.ClockQuality
    public let selected: Bool
    public let state: State
    public let priority1: UInt8
    public let priority2: UInt8
    public let address: PTP.PortAddress

    public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
      try portIdentity.serialize(into: &serializationContext)
      try clockQuality.serialize(into: &serializationContext)
      serializationContext.serialize(uint8: selected ? 1 : 0)
      try state.serialize(into: &serializationContext)
      serializationContext.serialize(uint8: priority1)
      serializationContext.serialize(uint8: priority2)
      try address.serialize(into: &serializationContext)
    }

    public init(parsing input: inout ParserSpan) throws {
      portIdentity = try PTP.PortIdentity(parsing: &input)
      clockQuality = try PTP.ClockQuality(parsing: &input)
      selected = try UInt8(parsing: &input) & 1 != 0
      state = try State(parsing: &input)
      priority1 = try UInt8(parsing: &input)
      priority2 = try UInt8(parsing: &input)
      address = try PTP.PortAddress(parsing: &input)
    }
  }

  public let entries: [Entry]

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    guard entries.count <= UInt16.max else { throw PTP.Error.valueTooLarge }
    serializationContext.serialize(uint16: UInt16(entries.count))
    for entry in entries {
      try entry.serialize(into: &serializationContext)
    }
  }

  public init(parsing input: inout ParserSpan) throws {
    let actualTableSize = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    entries = try (0..<actualTableSize).map { _ in try Entry(parsing: &input) }
  }
}

public struct PortHwclockNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PORT_HWCLOCK_NP }

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

    public static let vclock = Flags(rawValue: 1 << 0)
  }

  public let portIdentity: PTP.PortIdentity
  public let phcIndex: Int32
  public let flags: Flags
  private let reserved: UInt8

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try portIdentity.serialize(into: &serializationContext)
    serializationContext.serialize(int32: phcIndex)
    try flags.serialize(into: &serializationContext)
    serializationContext.serialize(uint8: reserved)
  }

  public init(parsing input: inout ParserSpan) throws {
    portIdentity = try PTP.PortIdentity(parsing: &input)
    phcIndex = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    flags = try Flags(parsing: &input)
    reserved = try UInt8(parsing: &input)
  }
}

public struct PowerProfileSettingsNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .POWER_PROFILE_SETTINGS_NP }

  public enum Version: UInt16, SerDes, Sendable {
    case none = 0
    case ieeeC37_238_2011 = 1
    case ieeeC37_238_2017 = 2

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

  public let version: Version
  public let grandmasterID: UInt16
  public let grandmasterTimeInaccuracy: UInt32
  public let networkTimeInaccuracy: UInt32
  public let totalTimeInaccuracy: UInt32

  init(
    version: Version,
    grandmasterID: UInt16,
    grandmasterTimeInaccuracy: UInt32,
    networkTimeInaccuracy: UInt32,
    totalTimeInaccuracy: UInt32
  ) {
    self.version = version
    self.grandmasterID = grandmasterID
    self.grandmasterTimeInaccuracy = grandmasterTimeInaccuracy
    self.networkTimeInaccuracy = networkTimeInaccuracy
    self.totalTimeInaccuracy = totalTimeInaccuracy
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    try version.serialize(into: &serializationContext)
    serializationContext.serialize(uint16: grandmasterID)
    serializationContext.serialize(uint32: grandmasterTimeInaccuracy)
    serializationContext.serialize(uint32: networkTimeInaccuracy)
    serializationContext.serialize(uint32: totalTimeInaccuracy)
  }

  public init(parsing input: inout ParserSpan) throws {
    version = try Version(parsing: &input)
    grandmasterID = try UInt16(parsing: &input, storedAsBigEndian: UInt16.self)
    grandmasterTimeInaccuracy = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
    networkTimeInaccuracy = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
    totalTimeInaccuracy = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
  }
}

public struct CmldsInfoNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .CMLDS_INFO_NP }

  public let meanLinkDelay: PTP.TimeInterval
  public let scaledNeighborRateRatio: Int32
  public let asCapable: UInt32

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(int64: meanLinkDelay)
    serializationContext.serialize(int32: scaledNeighborRateRatio)
    serializationContext.serialize(uint32: asCapable)
  }

  public init(parsing input: inout ParserSpan) throws {
    meanLinkDelay = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
    scaledNeighborRateRatio = try Int32(parsing: &input, storedAsBigEndian: Int32.self)
    asCapable = try UInt32(parsing: &input, storedAsBigEndian: UInt32.self)
  }
}

public struct PortCorrectionsNP: PTPManagementRepresentable {
  static var managementId: PTPManagementID { .PORT_CORRECTIONS_NP }

  // network order, per the pending ptp4l fix. Every daemon built to date drops the
  // net2host64()/host2net64() result here and exchanges these three in host order,
  // so do not set them until that fix has landed on the target.
  public let egressLatency: Int64
  public let ingressLatency: Int64
  public let delayAsymmetry: Int64

  init(egressLatency: Int64, ingressLatency: Int64, delayAsymmetry: Int64) {
    self.egressLatency = egressLatency
    self.ingressLatency = ingressLatency
    self.delayAsymmetry = delayAsymmetry
  }

  public func serialize(into serializationContext: inout IEEE802.SerializationContext) throws {
    serializationContext.serialize(int64: egressLatency)
    serializationContext.serialize(int64: ingressLatency)
    serializationContext.serialize(int64: delayAsymmetry)
  }

  public init(parsing input: inout ParserSpan) throws {
    egressLatency = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
    ingressLatency = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
    delayAsymmetry = try Int64(parsing: &input, storedAsBigEndian: Int64.self)
  }
}
