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

public protocol Deserializble: Sendable {
  init(deserializationContext: inout DeserializationContext) throws
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

  public mutating func serialize(eui48: EUI48, at index: Int? = nil) {
    let bytes = [eui48.0, eui48.1, eui48.2, eui48.3, eui48.4, eui48.5]
    serialize(bytes, at: index)
  }

  public var position: Int { bytes.count }
}

// don't want to use Foundation, hence no String(format:)
func _byteToHex(_ byte: UInt8, uppercase: Bool = false) -> String {
  let s = String(byte, radix: 16, uppercase: uppercase)
  if byte & 0xF0 == 0 {
    return "0" + s
  } else {
    return s
  }
}

func _bytesToHex(_ bytes: [UInt8], uppercase: Bool = false) -> String {
  bytes.map { _byteToHex($0) }.joined()
}

public struct DeserializationContext: CustomStringConvertible {
  private let bytes: [UInt8]
  public private(set) var position: Int

  public init(_ bytes: [UInt8]) {
    self.bytes = bytes
    position = 0
  }

  public var count: Int { bytes.count }

  public var description: String {
    "DeserializationContext(\(_bytesToHex(Array(bytes[position..<bytes.count]))))"
  }

  public var bytesRemaining: Int {
    bytes.count - position
  }

  public func assertRemainingLength(isAtLeast count: Int) throws {
    guard bytesRemaining >= count else {
      throw Errno.outOfRange
    }
  }

  public mutating func deserialize(count: Int) throws -> ArraySlice<UInt8> {
    try assertRemainingLength(isAtLeast: count)
    defer { position += count }
    return bytes[position..<(position + count)]
  }

  public func peek(count: Int) throws -> ArraySlice<UInt8> {
    try assertRemainingLength(isAtLeast: count)
    return bytes[position..<(position + count)]
  }

  public mutating func deserialize() throws -> UInt8 {
    try deserialize(count: 1).first!
  }

  public mutating func deserialize() throws -> UInt16 {
    try UInt16(bigEndianBytes: deserialize(count: 2))
  }

  public mutating func deserialize() throws -> UInt32 {
    try UInt32(bigEndianBytes: deserialize(count: 4))
  }

  public mutating func deserialize() throws -> UInt64 {
    try UInt64(bigEndianBytes: deserialize(count: 8))
  }

  public mutating func deserialize() throws -> EUI48 {
    let bytes = try Array(deserialize(count: 6))
    return (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
  }

  public mutating func deserializeRemaining() -> ArraySlice<UInt8> {
    bytes[position..<bytes.count]
  }

  public func peek() throws -> UInt8 {
    try peek(count: 1).first!
  }

  public func peek() throws -> UInt16 {
    try UInt16(bigEndianBytes: peek(count: 2))
  }

  public func peek() throws -> UInt32 {
    try UInt32(bigEndianBytes: peek(count: 4))
  }

  public func peek() throws -> UInt64 {
    try UInt64(bigEndianBytes: peek(count: 8))
  }
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
