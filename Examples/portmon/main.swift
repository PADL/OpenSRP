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

import MRP

let groupAddress: EUI48 = (0x01, 0x80, 0xC2, 0x00, 0x00, 0x20)
let etherType: UInt16 = 0x88F6

@main
struct portmon {
  public static func main() async throws {
    let bridge = try await LinuxBridge(
      name: CommandLine.arguments.count > 1 ? CommandLine
        .arguments[1] : "br0"
    )
    print("Ports at startup on bridge \(bridge.name):")
    for port in try await bridge.ports {
      print("\(port)")
      do {
        try port.addFilter(for: groupAddress, etherType: etherType)
        print("added filter for \(groupAddress).\(etherType)")
      } catch {
        print("failed to add filter for \(groupAddress).\(etherType): \(error)")
        throw error
      }
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { @Sendable in
        print("Now monitoring for changes...")
        for try await notification in bridge.notifications {
          print("\(notification)")
        }
      }
      group.addTask { @Sendable in
        print("Now monitoring for packets...")
        for port in try await bridge.ports {
          do {
            for try await packet in try await port.rxPackets {
              print("received packet \(packet)\n\(packet.data.hexEncodedString())")
            }
          } catch {
            print("failed to RX packet on \(port): \(error)")
          }
        }
      }
      for try await _ in group {}
    }
  }
}

extension [UInt8] {
  struct HexEncodingOptions: OptionSet {
    let rawValue: Int
    static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
  }

  func hexEncodedString(options: HexEncodingOptions = []) -> String {
    let hexDigits = options.contains(.upperCase) ? "0123456789ABCDEF" : "0123456789abcdef"
    let utf8Digits = Array(hexDigits.utf8)
    return String(unsafeUninitializedCapacity: 2 * self.count) { ptr -> Int in
      var p = ptr.baseAddress!
      for byte in self {
        p[0] = utf8Digits[Int(byte / 16)]
        p[1] = utf8Digits[Int(byte % 16)]
        p += 2
      }
      return 2 * self.count
    }
  }
}
