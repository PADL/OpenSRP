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
}

enum MSRPApplicationEvent: ApplicationEvent {
  case ignore = 0
  case askignFailed = 1
  case ready = 2
  case readyFailed = 3
}

protocol MSRPTalkerValue: Value {
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

struct MSRPTalkerAdvertiseValue: MSRPTalkerValue, Equatable {
  let streamID: UInt64
  let dataFrameParameters: MSRPDataFrameParameters
  let tSpec: MSRPTSpec
  let priorityAndRank: MSRPPriorityAndRank
  let accumulatedLatency: UInt32

  var index: Int { Int(streamID & 0x1FFF) }

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

  init(firstValue: Self?, index: Int) throws {
    if let firstValue {
      try self.init(
        streamID: firstValue.streamID + UInt64(index),
        dataFrameParameters: firstValue.dataFrameParameters.makeValue(relativeTo: index),
        tSpec: firstValue.tSpec,
        priorityAndRank: firstValue.priorityAndRank,
        accumulatedLatency: firstValue.accumulatedLatency
      )
    } else {
      try self.init(
        streamID: UInt64(index),
        dataFrameParameters: MSRPDataFrameParameters(index: index)
      )
    }
  }
}

struct MSRPTalkerFailedValue: MSRPTalkerValue, Equatable {
  let streamID: UInt64
  let dataFrameParameters: MSRPDataFrameParameters
  let tSpec: MSRPTSpec
  let priorityAndRank: MSRPPriorityAndRank
  let accumulatedLatency: UInt32
  let systemID: UInt64
  let failureCode: TSNFailureCode

  var index: Int { Int(streamID & 0x1FFF) }

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

  init(firstValue: Self?, index: Int) throws {
    if let firstValue {
      try self.init(
        streamID: firstValue.streamID + UInt64(index),
        dataFrameParameters: firstValue.dataFrameParameters.makeValue(relativeTo: index),
        tSpec: firstValue.tSpec,
        priorityAndRank: firstValue.priorityAndRank,
        accumulatedLatency: firstValue.accumulatedLatency,
        systemID: firstValue.systemID,
        failureCode: firstValue.failureCode
      )
    } else {
      try self.init(
        streamID: UInt64(index),
        dataFrameParameters: MSRPDataFrameParameters(index: index)
      )
    }
  }
}

struct MSRPListenerValue: Value, Equatable {
  let streamID: UInt64

  var index: Int { Int(streamID & 0x1FFF) }

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

  init(firstValue: Self?, index: Int) throws {
    self.init(streamID: firstValue?.streamID ?? 0 + UInt64(index))
  }
}

struct MSRPDomainValue: Value, Equatable {
  let srClassID: SRclassID
  let srClassPriority: SRclassPriority
  let srClassVID: SRclassVID

  var index: Int {
    Int(srClassID.rawValue)
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

  init(firstValue: MSRPDomainValue?, index: Int) throws {
    let value = Int(firstValue?.srClassID.rawValue ?? 0) + index
    guard value < 8 else {
      throw MRPError.invalidAttributeValue
    }
    guard let srClassID = SRclassID(rawValue: UInt8(value)) else {
      throw MRPError.invalidSRclassID
    }
    self.srClassID = srClassID
    guard let srClassPriority = SRclassPriority(rawValue: UInt8(value)) else {
      throw MRPError.invalidSRclassPriority
    }
    self.srClassPriority = srClassPriority
    srClassVID = 0
  }
}
