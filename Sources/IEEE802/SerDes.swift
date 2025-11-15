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
import SystemPackage

public protocol Serializable: Sendable {
  func serialize(into: inout SerializationContext) throws
}

public extension Serializable {
  func serialized() throws -> [UInt8] {
    var serializationContext = SerializationContext()
    try serialize(into: &serializationContext)
    return serializationContext.bytes
  }
}

public protocol Deserializble: Sendable, ExpressibleByParsing {
  init(parsing input: inout ParserSpan) throws
}

public protocol SerDes: Serializable, Deserializble {}

public struct SerializationContext {
  public private(set) var bytes = [UInt8]()

  public init() {}

  public mutating func reserveCapacity(_ capacity: Int) {
    bytes.reserveCapacity(capacity)
  }

  public mutating func serialize(_ bytes: [UInt8], at index: Int? = nil) {
    if let index {
      precondition(self.bytes.count >= index + bytes.count)
      self.bytes.replaceSubrange(index..<(index + bytes.count), with: bytes)
    } else {
      self.bytes += bytes
    }
  }

  public mutating func serialize(uint8: UInt8, at index: Int? = nil) {
    serialize([uint8], at: index)
  }

  public mutating func serialize(uint16: UInt16, at index: Int? = nil) {
    serialize(uint16.bigEndianBytes, at: index)
  }

  public mutating func serialize(uint32: UInt32, at index: Int? = nil) {
    serialize(uint32.bigEndianBytes, at: index)
  }

  public mutating func serialize(uint64: UInt64, at index: Int? = nil) {
    serialize(uint64.bigEndianBytes, at: index)
  }

  public mutating func serialize(int8: Int8, at index: Int? = nil) {
    serialize([UInt8(bitPattern: int8)], at: index)
  }

  public mutating func serialize(int16: Int16, at index: Int? = nil) {
    serialize(int16.bigEndianBytes, at: index)
  }

  public mutating func serialize(int32: Int32, at index: Int? = nil) {
    serialize(int32.bigEndianBytes, at: index)
  }

  public mutating func serialize(int64: Int64, at index: Int? = nil) {
    serialize(int64.bigEndianBytes, at: index)
  }

  public mutating func serialize(eui48: EUI48, at index: Int? = nil) {
    let bytes = [eui48.0, eui48.1, eui48.2, eui48.3, eui48.4, eui48.5]
    serialize(bytes, at: index)
  }

  public var position: Int { bytes.count }
}

// https://forums.swift.org/t/string-format-behaves-differently-on-windows/65197/6
package func _formatHex(
  _ value: some BinaryInteger,
  padToWidth: Int = 16,
  uppercase: Bool = false
) -> String {
  let base = String(value, radix: 16, uppercase: uppercase)
  let pad = String(repeating: "0", count: max(0, padToWidth - base.count))
  return "\(pad)\(base)"
}

// don't want to use Foundation, hence no String(format:)
package func _byteToHex(_ byte: UInt8, uppercase: Bool = false) -> String {
  _formatHex(byte, padToWidth: 2, uppercase: uppercase)
}

package func _bytesToHex(_ bytes: [UInt8], uppercase: Bool = false) -> String {
  bytes.map { _byteToHex($0) }.joined()
}

// MARK: - Helper function for EUI48

package func _eui48(parsing input: inout ParserSpan) throws -> EUI48 {
  try (
    UInt8(parsing: &input),
    UInt8(parsing: &input),
    UInt8(parsing: &input),
    UInt8(parsing: &input),
    UInt8(parsing: &input),
    UInt8(parsing: &input)
  )
}

extension FixedWidthInteger {
  init<I>(bigEndianBytes iterator: inout I)
    where I: IteratorProtocol, I.Element == UInt8
  {
    self = stride(from: 8, to: Self.bitWidth + 8, by: 8).reduce(into: 0) {
      $0 |= Self(truncatingIfNeeded: iterator.next()!) &<< (Self.bitWidth - $1)
    }
  }

  init(bigEndianBytes bytes: some Collection<UInt8>) {
    precondition(bytes.count == (Self.bitWidth + 7) / 8)
    var iter = bytes.makeIterator()
    self.init(bigEndianBytes: &iter)
  }

  var bigEndianBytes: [UInt8] {
    let count = Self.bitWidth / 8
    var bigEndian = bigEndian
    return [UInt8](withUnsafePointer(to: &bigEndian) {
      $0.withMemoryRebound(to: UInt8.self, capacity: count) {
        UnsafeBufferPointer(start: $0, count: count)
      }
    })
  }

  func serialize(into bytes: inout [UInt8]) throws {
    bytes += bigEndianBytes
  }
}
