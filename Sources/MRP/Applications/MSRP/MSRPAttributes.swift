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

enum MSRPAttributeType: AttributeType, CaseIterable {
  // Talker Advertise Vector (25 octets)
  case talkerAdvertise = 1
  // Talker Failed Vector (34 octets)
  case talkerFailed = 2
  // Listener Vector (8 octets)
  case listener = 3
  // Domain Vector (4 octets)
  case domain = 4
  // Talker Enhanced Vector (variable)
  // case talkerEnhanced = 5 // v1 only
  // Listener Enhanced Vector (variable)
  // case listenerEnhanced = 6 // v1 only

  static var validAttributeTypes: ClosedRange<AttributeType> {
    allCases.first!.rawValue...allCases.last!.rawValue
  }

  var direction: MSRPDirection? {
    switch self {
    case .talkerAdvertise:
      fallthrough
    case .talkerFailed:
      return .talker
    case .listener:
      return .listener
    default:
      return nil
    }
  }
}

enum MSRPAttributeSubtype: AttributeSubtype {
  case ignore = 0
  case askingFailed = 1
  case ready = 2
  case readyFailed = 3
}

protocol MSRPStreamIDRepresentable: Sendable {
  var streamID: MSRPStreamID { get }
}

protocol MSRPTalkerValue: Value, MSRPStreamIDRepresentable {
  var streamID: MSRPStreamID { get }
  var dataFrameParameters: MSRPDataFrameParameters { get }
  var tSpec: MSRPTSpec { get }
  var priorityAndRank: MSRPPriorityAndRank { get }
  var accumulatedLatency: UInt32 { get }
}

private extension MSRPTalkerValue {
  func _serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint64: streamID)
    try dataFrameParameters.serialize(into: &serializationContext)
    try tSpec.serialize(into: &serializationContext)
    try priorityAndRank.serialize(into: &serializationContext)
    serializationContext.serialize(uint32: accumulatedLatency)
  }
}

struct MSRPTalkerAdvertiseValue: MSRPTalkerValue, MSRPStreamIDRepresentable, Equatable {
  let streamID: UInt64
  let dataFrameParameters: MSRPDataFrameParameters
  let tSpec: MSRPTSpec
  let priorityAndRank: MSRPPriorityAndRank
  let accumulatedLatency: UInt32

  var index: UInt64 { streamID }

  init(
    streamID: UInt64,
    dataFrameParameters: MSRPDataFrameParameters = MSRPDataFrameParameters(),
    tSpec: MSRPTSpec = MSRPTSpec(),
    priorityAndRank: MSRPPriorityAndRank = MSRPPriorityAndRank(),
    accumulatedLatency: UInt32 = 0
  ) {
    self.streamID = streamID
    self.dataFrameParameters = dataFrameParameters
    self.tSpec = tSpec
    self.priorityAndRank = priorityAndRank
    self.accumulatedLatency = accumulatedLatency
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    try _serialize(into: &serializationContext)
  }

  public init(deserializationContext: inout DeserializationContext) throws {
    streamID = try deserializationContext.deserialize()
    dataFrameParameters =
      try MSRPDataFrameParameters(deserializationContext: &deserializationContext)
    tSpec = try MSRPTSpec(deserializationContext: &deserializationContext)
    priorityAndRank = try MSRPPriorityAndRank(deserializationContext: &deserializationContext)
    accumulatedLatency = try deserializationContext.deserialize()
  }

  init() {
    self.init(streamID: 0, dataFrameParameters: MSRPDataFrameParameters())
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    try Self(
      streamID: streamID + index,
      dataFrameParameters: dataFrameParameters.makeValue(relativeTo: index),
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: accumulatedLatency
    )
  }
}

struct MSRPTalkerFailedValue: MSRPTalkerValue, MSRPStreamIDRepresentable, Equatable {
  let streamID: UInt64
  let dataFrameParameters: MSRPDataFrameParameters
  let tSpec: MSRPTSpec
  let priorityAndRank: MSRPPriorityAndRank
  let accumulatedLatency: UInt32
  let systemID: UInt64
  let failureCode: TSNFailureCode

  var index: UInt64 { streamID }

  init(
    streamID: UInt64,
    dataFrameParameters: MSRPDataFrameParameters = MSRPDataFrameParameters(),
    tSpec: MSRPTSpec = MSRPTSpec(),
    priorityAndRank: MSRPPriorityAndRank = MSRPPriorityAndRank(),
    accumulatedLatency: UInt32 = 0,
    systemID: UInt64 = 0,
    failureCode: TSNFailureCode = .insufficientBandwidth
  ) {
    self.streamID = streamID
    self.dataFrameParameters = dataFrameParameters
    self.tSpec = tSpec
    self.priorityAndRank = priorityAndRank
    self.accumulatedLatency = accumulatedLatency
    self.systemID = systemID
    self.failureCode = failureCode
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    try _serialize(into: &serializationContext)
    serializationContext.serialize(uint64: systemID)
    try failureCode.serialize(into: &serializationContext)
  }

  public init(deserializationContext: inout DeserializationContext) throws {
    streamID = try deserializationContext.deserialize()
    dataFrameParameters =
      try MSRPDataFrameParameters(deserializationContext: &deserializationContext)
    tSpec = try MSRPTSpec(deserializationContext: &deserializationContext)
    priorityAndRank = try MSRPPriorityAndRank(deserializationContext: &deserializationContext)
    accumulatedLatency = try deserializationContext.deserialize()
    systemID = try deserializationContext.deserialize()
    failureCode = try TSNFailureCode(deserializationContext: &deserializationContext)
  }

  init() {
    self.init(streamID: 0, dataFrameParameters: MSRPDataFrameParameters())
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    try Self(
      streamID: streamID + UInt64(index),
      dataFrameParameters: dataFrameParameters.makeValue(relativeTo: index),
      tSpec: tSpec,
      priorityAndRank: priorityAndRank,
      accumulatedLatency: accumulatedLatency,
      systemID: systemID,
      failureCode: failureCode
    )
  }
}

struct MSRPListenerValue: Value, Equatable {
  let streamID: UInt64

  var index: UInt64 { streamID }

  init(
    streamID: UInt64
  ) {
    self.streamID = streamID
  }

  public func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint64: streamID)
  }

  public init(deserializationContext: inout DeserializationContext) throws {
    streamID = try deserializationContext.deserialize()
  }

  public init() {
    self.init(streamID: 0)
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    Self(streamID: streamID + index)
  }
}

struct MSRPDomainValue: Value, Equatable {
  let srClassID: SRclassID
  let srClassPriority: SRclassPriority
  let srClassVID: SRclassVID

  var index: UInt64 {
    UInt64(srClassID.rawValue)
  }

  var vlan: VLAN {
    VLAN(vid: srClassVID)
  }

  init(srClassID: SRclassID, srClassPriority: SRclassPriority, srClassVID: SRclassVID) {
    self.srClassID = srClassID
    self.srClassPriority = srClassPriority
    self.srClassVID = srClassVID
  }

  func serialize(into serializationContext: inout SerializationContext) throws {
    serializationContext.serialize(uint8: srClassID.rawValue)
    serializationContext.serialize(uint8: srClassPriority.rawValue)
    serializationContext.serialize(uint16: srClassVID)
  }

  init(deserializationContext: inout DeserializationContext) throws {
    guard let srClassID = try SRclassID(rawValue: deserializationContext.deserialize()) else {
      throw MRPError.invalidSRclassID
    }
    self.srClassID = srClassID
    guard let srClassPriority = try SRclassPriority(rawValue: deserializationContext.deserialize())
    else {
      throw MRPError.invalidSRclassPriority
    }
    self.srClassPriority = srClassPriority
    let srClassVID: UInt16 = try deserializationContext.deserialize()
    guard srClassVID & 0xF000 == 0 else {
      throw MRPError.invalidSRclassVID
    }
    self.srClassVID = srClassVID
  }

  init() throws {
    self.init(srClassID: .B, srClassPriority: .EE, srClassVID: SR_PVID.vid)
  }

  public func makeValue(relativeTo index: UInt64) throws -> Self {
    let value = UInt64(srClassID.rawValue) + index
    guard value < 8 else {
      throw MRPError.invalidAttributeValue
    }
    guard let srClassID = SRclassID(rawValue: UInt8(value)) else {
      throw MRPError.invalidSRclassID
    }
    guard let srClassPriority = SRclassPriority(rawValue: UInt8(value)) else {
      throw MRPError.invalidSRclassPriority
    }
    return Self(srClassID: srClassID, srClassPriority: srClassPriority, srClassVID: SR_PVID.vid)
  }
}
