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

@_spi(SwiftMRPPrivate)
import MRP

@main
actor PortMonitor {
  typealias P = LinuxPort
  typealias B = LinuxBridge

  public static func main() async throws {
    let portmon = PortMonitor()
    try await portmon.run()
  }

  var ports = Set<P>()

  func handle(notification: PortNotification<P>) {
    print("\(notification)")
    switch notification {
    case let .added(port): ports.insert(port)
    case let .removed(port): ports.remove(port)
    case let .changed(port): ports.update(with: port)
    }
  }

  func findPort(_ id: P.ID) -> P? {
    ports.first(where: { $0.id == id })
  }

  func run() async throws {
    let bridge = try await B(
      name: CommandLine.arguments.count > 1 ? CommandLine
        .arguments[1] : "br0",
      netFilterGroup: 10
    )

    // now we need to register to ensure RX task is created
    // we can do this for every application we wish to monitor
    try bridge.register(groupAddress: IndividualLANScopeGroupAddress, etherType: 0x22EA) // MSRP
    try bridge.register(groupAddress: CustomerBridgeMVRPGroupAddress, etherType: 0x88F5) // MVRP

    ports = try await bridge.getPorts()
    print("Ports at startup on bridge \(bridge.name):")
    for port in ports {
      print("\(port)")
    }

    try bridge.willRun(ports: ports)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { @Sendable in
        print("Monitoring for bridge notifications...")
        for try await notification in bridge.notifications {
          await self.handle(notification: notification)
        }
      }
      group.addTask { @Sendable in
        print("Monitoring bridge RX packets...")
        do {
          for try await (index, packet) in bridge.rxPackets {
            await print(
              "\(self.findPort(index)!): received packet \(packet)\n\(packet.payload.hexEncodedString())"
            )
          }
        } catch {
          print("bridge failed to RX packet: \(error)")
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
