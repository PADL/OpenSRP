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

import SystemPackage

public typealias EUI48 = InlineArray<6, UInt8>

public extension UInt64 {
  init(eui48: EUI48) {
    self =
      UInt64(eui48[0]) << 40 |
      UInt64(eui48[1]) << 32 |
      UInt64(eui48[2]) << 24 |
      UInt64(eui48[3]) << 16 |
      UInt64(eui48[4]) << 8 |
      UInt64(eui48[5]) << 0
  }

  func asEUI48() throws -> EUI48 {
    guard (self & 0xFFFF_0000_0000_0000) == 0 else {
      throw Errno.invalidArgument
    }

    return [
      UInt8((self >> 40) & 0xFF),
      UInt8((self >> 32) & 0xFF),
      UInt8((self >> 24) & 0xFF),
      UInt8((self >> 16) & 0xFF),
      UInt8((self >> 8) & 0xFF),
      UInt8((self >> 0) & 0xFF),
    ]
  }
}

// used by MVRP and MMRP (forwarded by bridges that do not support application protocol)
public let CustomerBridgeMRPGroupAddress: EUI48 = [0x01, 0x80, 0xC2, 0x00, 0x00, 0x21]

// used by MSRP (not forwarded by bridges)
public let IndividualLANScopeGroupAddress: EUI48 = [0x01, 0x80, 0xC2, 0x00, 0x00, 0x0E]

public func _isLinkLocal(macAddress: EUI48) -> Bool {
  macAddress[0] == 0x01 && macAddress[1] == 0x80 && macAddress[2] == 0xC2 && macAddress[3] ==
    0x00 &&
    macAddress[4] == 0x00 && macAddress[5] & 0xF0 == 0
}

public func _isEqualMacAddress(_ lhs: EUI48, _ rhs: EUI48) -> Bool {
  lhs[0] == rhs[0] &&
    lhs[1] == rhs[1] &&
    lhs[2] == rhs[2] &&
    lhs[3] == rhs[3] &&
    lhs[4] == rhs[4] &&
    lhs[5] == rhs[5]
}

public func _isMulticast(macAddress: EUI48) -> Bool {
  macAddress[0] & 1 != 0
}

public func _hashMacAddress(_ macAddress: EUI48, into hasher: inout Hasher) {
  macAddress[0].hash(into: &hasher)
  macAddress[1].hash(into: &hasher)
  macAddress[2].hash(into: &hasher)
  macAddress[3].hash(into: &hasher)
  macAddress[4].hash(into: &hasher)
  macAddress[5].hash(into: &hasher)
}

private func _hexFormat(_ value: UInt8, colonSuffix: Bool = true) -> String {
  _byteToHex(value) + (colonSuffix ? ":" : "")
}

public func _macAddressToString(_ macAddress: EUI48) -> String {
  _hexFormat(macAddress[0]) +
    _hexFormat(macAddress[1]) +
    _hexFormat(macAddress[2]) +
    _hexFormat(macAddress[3]) +
    _hexFormat(macAddress[4]) +
    _hexFormat(macAddress[5], colonSuffix: false)
}

public func _stringToMacAddress(_ macString: String) -> EUI48? {
  let components = macString.split(separator: ":")

  // Only support colon-separated format: "01:02:03:04:05:06" (6 components)
  guard components.count == 6 else {
    return nil
  }

  let bytes = components.compactMap { component -> UInt8? in
    guard component.count == 2 else { return nil }
    return UInt8(component, radix: 16)
  }

  guard bytes.count == 6 else {
    return nil
  }

  return [bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]]
}
