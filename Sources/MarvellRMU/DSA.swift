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

public let DSAEtherType: UInt16 = 0xDADA

// https://www.tcpdump.org/linktypes/marvell-switch-tag.html
public struct DSATag: Sendable, Equatable {
  let _tag: UInt32

  public typealias TCI = IEEE802Packet.TCI

  public enum Mode: UInt8 {
    case To_CPU = 0
    case From_CPU = 1
    case To_Sniffer = 2
    case Forward = 3
  }

  public var mode: Mode {
    Mode(rawValue: UInt8(_tag & 0xC000_0000) >> 30)!
  }

  public enum ToCPUCode: UInt8 {
    case mgmtTrap = 0
    case frame2reg = 1
    case igmpMldTrap = 2
    case policyTrap = 3
    case arpMirror = 4
    case policyMirror = 5
  }

  public var toCPUCode: ToCPUCode? {
    guard mode == .To_CPU else { return nil }
    var rawValue: UInt8 = 0
    if _b12 { rawValue |= 0x1 }
    if _b17 { rawValue |= 0x2 }
    if _b18 { rawValue |= 0x4 }
    return ToCPUCode(rawValue: rawValue)
  }

  public var cfi: Bool? {
    guard isTagged else { return nil }
    return _b16
  }

  var _b29: Bool {
    _tag & 0x2000_0000 != 0
  }

  var _b18: Bool {
    _tag & 0x0004_0000 != 0
  }

  var _b17: Bool {
    _tag & 0x0002_0000 != 0
  }

  var _b16: Bool {
    _tag & 0x0001_0000 != 0
  }

  var _b12: Bool {
    _tag & 0x0000_1000 != 0
  }

  public var isTagged: Bool {
    _b29
  }

  public var switchDevice: UInt16 {
    UInt16((_tag & 0x1F00_0000) >> 24)
  }

  public var switchPort: UInt16 {
    UInt16((_tag & 0x00F8_0000) >> 19)
  }

  public var tci: TCI? {
    guard isTagged else { return nil }

    // handle remapping of DEI bit
    var tci = TCI(UInt16(_tag & 0xE000))
    if _b16 { tci.dei = true }
    tci.vid = UInt16(_tag & 0xFFF)

    return tci
  }

  init(_tag: UInt32) {
    self._tag = _tag
  }

  public init(isTagged: Bool, switchDevice: UInt16, switchPort: UInt16, tci: TCI?) throws {
    var tag = UInt32(Mode.From_CPU.rawValue) << 30
    if isTagged {
      tag |= 0x2000_0000
    }

    if let tci {
      if tci.dei {
        tag |= 0x0001_0000
      }

      tag |= UInt32(tci.tci & 0xEFFF)
    }

    guard switchDevice & ~0x1F == 0, switchPort & ~0x1F == 0 else { throw Errno.invalidArgument }
    tag |= UInt32(switchDevice & 0x1F) << 24
    tag |= UInt32(switchPort & 0x1F) << 19

    self.init(_tag: tag)
  }
}

public extension DSATag {
  var sourceDevice: UInt16? {
    guard mode != .From_CPU else { return nil }
    return switchDevice
  }

  var isTrunk: Bool? {
    guard mode == .Forward else { return nil }
    return _b18
  }

  var sourcePort: UInt16? {
    guard (mode == .Forward && isTrunk == false) || mode == .To_CPU || mode == .To_Sniffer
    else { return nil }
    return switchPort
  }

  var sourceTrunk: UInt16? {
    guard mode == .Forward, isTrunk == true else { return nil }
    return switchPort
  }

  var targetDevice: UInt16? {
    guard mode == .From_CPU else { return nil }
    return switchDevice
  }

  var targetPort: UInt16? {
    guard mode == .From_CPU else { return nil }
    return switchPort
  }
}

public extension IEEE802Packet {
  init(
    destMacAddress: EUI48,
    sourceMacAddress: EUI48,
    dsaTag: DSATag,
    etherType: UInt16,
    payload: [UInt8]
  ) {
    var serializationContext = SerializationContext()

    serializationContext.serialize(uint16: 0)
    serializationContext.serialize(uint32: dsaTag._tag)
    serializationContext.serialize(uint16: etherType)
    serializationContext.serialize(payload)

    self.init(
      destMacAddress: destMacAddress,
      tci: nil,
      sourceMacAddress: sourceMacAddress,
      etherType: DSAEtherType,
      payload: serializationContext.bytes
    )
  }

  func toDsa() throws -> (DSATag, UInt16, [UInt8]) {
    guard etherType == DSAEtherType else { throw Errno.invalidArgument }

    var deserializationContext = DeserializationContext(payload)

    let _: UInt16 = try deserializationContext.deserialize()
    let tag: UInt32 = try deserializationContext.deserialize()
    let etherType: UInt16 = try deserializationContext.deserialize()
    let dsaPayload = deserializationContext.deserializeRemaining()

    return (DSATag(_tag: tag), etherType, Array(dsaPayload))
  }
}
