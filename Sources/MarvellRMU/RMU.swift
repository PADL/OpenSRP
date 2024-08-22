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

import IEEE802
import SystemPackage

public let RMUGroupAddress: EUI48 = (0x01, 0x50, 0x43, 0x00, 0x00, 0x00)

public let RMUEtherType: UInt16 = 0x00FB

public enum RMUFormat: UInt16, Sendable {
  // MV88E6XXX_RMU_REQ_FORMAT_GET_ID
  case GetID = 0x0000
  // MV88E6XXX_RMU_REQ_FORMAT_SOHO / MV88E6XXX_RMU_RESP_FORMAT_1
  case Format1 = 0x0001
  // MV88E6XXX_RMU_RESP_FORMAT_2
  case Format2 = 0x0002
  case Error = 0xFFFF
}

public enum RMUCode: UInt16, Sendable {
  // MV88E6XXX_RMU_REQ_CODE_GET_ID
  case GotID = 0x0000
  case GetID = 0x0001
  case DumpATU = 0x1000
  // MV88E6XXX_RMU_REQ_CODE_DUMP_MIB
  case DumpMIB = 0x1020
  case RegisterOperation = 0x2000
}

public struct RMURequestResponse: Sendable {
  public let format: RMUFormat
  public let productNum: UInt8
  public let productRev: UInt8
  public let code: RMUCode
  public let data: [UInt8]

  public init(
    format: RMUFormat,
    productNum: UInt8 = 0,
    productRev: UInt8 = 0,
    code: RMUCode,
    data: [UInt8]
  ) {
    self.format = format
    self.productNum = productNum
    self.productRev = productRev
    self.code = code
    self.data = data
  }

  public init(registerOp: [RMURegisterOperation]) {
    format = .Format1
    productNum = 0
    productRev = 0
    code = .RegisterOperation
    data = registerOp.map(\._reg.bigEndian).withUnsafeBytes(Array.init)
  }
}

public struct RMUMIBResponse: Sendable {
  public let switchDevice: UInt8
  public let switchPort: UInt8
  public let timestamp: UInt32
  public let mib: [UInt32]

  init(rmuResponse: RMURequestResponse) throws {
    guard rmuResponse.format == .Format1 else { throw Errno.invalidArgument }
    guard rmuResponse.code == .DumpMIB else { throw Errno.invalidArgument }
    var deserializationContext = DeserializationContext(rmuResponse.data)
    switchDevice = try deserializationContext.deserialize() & 0x1F
    switchPort = try (deserializationContext.deserialize() >> 3) & 0x1F
    timestamp = try deserializationContext.deserialize()
    var mib = [UInt32]()
    while deserializationContext.position < deserializationContext.count {
      try mib.append(deserializationContext.deserialize())
    }
    self.mib = mib
  }
}

public struct RMURegisterOperation: Sendable {
  fileprivate let _reg: UInt32

  public static let EndOfList = RMURegisterOperation(_reg: 0xFFFF_FFFF)

  public enum Code: UInt8, Sendable {
    case readRegister = 0x08
    case writeRegister = 0x01
    case waitOnBit0 = 0x10
    case waitOnBit1 = 0x1C
  }

  public var code: Code? {
    Code(rawValue: UInt8(_reg >> 24))
  }

  public var smiDeviceAddress: UInt8 {
    UInt8((_reg & 0x03E0_0000) >> 21)
  }

  public var smiRegisterOffset: UInt8 {
    UInt8((_reg & 0x001F_0000) >> 16)
  }

  public var data: UInt16 {
    UInt16(_reg & 0xFFFF)
  }

  private init(_reg: UInt32) {
    self._reg = _reg
  }

  public init(code: Code, smiDeviceAddress: UInt8, smiRegisterOffset: UInt8, data: UInt16) {
    self
      .init(
        _reg: UInt32(code.rawValue) << 24 | UInt32(smiDeviceAddress & 0x1F) << 21 |
          UInt32(smiRegisterOffset & 0x1F) << 16 | UInt32(data)
      )
  }
}

public extension DSATag {
  var isRMURequest: Bool {
    mode == .From_CPU && !_b29 && (_tag & 0x3E0000) == 0x3E0000 && _b17 && !_b16 && !_b12 &&
      (_tag & 0xF00 == 0xF00)
  }

  var isRMUResponse: Bool {
    mode == .To_CPU && !_b29 && switchPort == 0 && toCPUCode == .frame2reg && !_b16 &&
      (_tag & 0xF00 == 0xF00)
  }

  var sequenceNum: UInt8? {
    guard isRMURequest || isRMUResponse else { return nil }
    return UInt8(_tag & 0xFF)
  }
}
