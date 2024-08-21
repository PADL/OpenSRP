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

public struct IEEE802Packet: Sendable, CustomStringConvertible {
  public static let IEEE8021QTagged: UInt16 = 0x8100

  public struct TCI: Sendable {
    public var tci: UInt16

    public enum PCP: UInt8, Sendable {
      case BK = 0
      case BE = 1
      case EE = 2 // class B
      case CA = 3 // class A
      case VI = 4
      case VO = 5
      case IC = 6
      case NC = 7
    }

    public var pcp: PCP {
      get {
        PCP(rawValue: UInt8((tci & 0xE000) >> 13))!
      }
      set {
        let value = UInt16(newValue.rawValue) << 13
        tci |= value & 0xE000
      }
    }

    public var dei: Bool {
      get {
        tci & 0x1000 != 0
      }
      set {
        if newValue { tci |= 0x1000 }
        else { tci &= ~0x1000 }
      }
    }

    public var vid: UInt16 {
      get {
        tci & 0xFFF
      }
      set {
        precondition(vid > 0 && vid < 0xFFF)
        tci &= ~0xFFF
        tci |= (newValue & 0xFFF)
      }
    }

    public init(tci: UInt16) {
      self.tci = tci
    }
  }

  public let destMacAddress: EUI48
  public let sourceMacAddress: EUI48
  public let tci: TCI?
  public let etherType: UInt16
  public let payload: [UInt8]

  public var vid: UInt16? {
    tci?.vid
  }

  public init(
    destMacAddress: EUI48,
    tci: TCI?,
    sourceMacAddress: EUI48,
    etherType: UInt16,
    payload: [UInt8]
  ) {
    self.destMacAddress = destMacAddress
    self.sourceMacAddress = sourceMacAddress
    self.tci = tci
    self.etherType = etherType
    self.payload = payload
  }

  private var _etherTypeString: String {
    String((etherType >> 16) & 0xFF, radix: 16, uppercase: false) +
      String(etherType & 0xFF, radix: 16, uppercase: false)
  }

  public var description: String {
    "IEEE802Packet(destMacAddress: \(_macAddressToString(destMacAddress)), " +
      "sourceMacAddress: \(_macAddressToString(sourceMacAddress)), " +
      "vid: \(vid ?? 0), etherType: \(_etherTypeString), packetLength: \(payload.count)"
  }
}
