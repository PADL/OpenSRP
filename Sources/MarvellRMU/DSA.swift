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

public struct DSATag {
  private let _tag: UInt32

  public typealias TCI = IEEE802Packet.TCI

  // https://www.tcpdump.org/linktypes/marvell-switch-tag.html

  public enum TagMode: UInt8 {
    case To_CPU = 0
    case From_CPU = 1
    case To_Sniffer = 2
    case Forward = 3
  }

  public var tagMode: TagMode {
    TagMode(rawValue: UInt8(_tag & 0xC000_0000) >> 30)!
  }

  public enum FrameTypeCode: UInt8 {
    case mgmtTrap = 0
    case frame2reg = 1
    case igmpMldTrap = 2
    case policyTrap = 3
    case arpMirror = 4
    case policyMirror = 5
  }

  public var frameTypeCode: FrameTypeCode? {
    guard tagMode == .To_CPU else { return nil }
    var rawValue: UInt8 = 0
    if _b12 { rawValue |= 0x1 }
    if _b17 { rawValue |= 0x2 }
    if _b18 { rawValue |= 0x4 }
    return FrameTypeCode(rawValue: rawValue)
  }

  public var cfi: Bool? {
    guard isTagged else { return nil }
    return _b16
  }

  private var _b29: Bool {
    _tag & 0x2000_0000 != 0
  }

  private var _b18: Bool {
    _tag & 0x0004_0000 != 0
  }

  private var _b17: Bool {
    _tag & 0x0002_0000 != 0
  }

  private var _b16: Bool {
    _tag & 0x0001_0000 != 0
  }

  private var _b16_18: UInt8 {
    UInt8((_tag & 0x0007_0000) >> 16)
  }

  private var _b12: Bool {
    tci.dei
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

  public var tci: TCI {
    TCI(tci: UInt16(_tag & 0xFFFF))
  }
}

public struct DSAPacket {
  // DA || SA || 0xdada || 0x0000 || DSA || ET || payload
}
