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

protocol Serializable: Sendable {
  func serialize(into: inout SerializationContext) throws
}

extension Serializable {
  func serialized() throws -> [UInt8] {
    var serializationContext = SerializationContext(bytes: [])
    try serialize(into: &serializationContext)
    return serializationContext.bytes
  }
}

protocol Deserializble: Sendable {
  init(deserializationContext: inout DeserializationContext) throws
}

protocol SerDes: Serializable, Deserializble {}

struct SerializationContext {
  private(set) var bytes = [UInt8]()

  mutating func reserveCapacity(_ capacity: Int) {
    bytes.reserveCapacity(capacity)
  }

  mutating func serialize(_ bytes: [UInt8], at index: Int? = nil) {
    if let index {
      precondition(self.bytes.count >= index + bytes.count)
      self.bytes.replaceSubrange(index..<(index + bytes.count), with: bytes)
    } else {
      self.bytes += bytes
    }
  }

  mutating func serialize(uint8: UInt8, at index: Int? = nil) {
    serialize([uint8], at: index)
  }

  mutating func serialize(uint16: UInt16, at index: Int? = nil) {
    serialize(uint16.bigEndianBytes, at: index)
  }

  mutating func serialize(uint32: UInt32, at index: Int? = nil) {
    serialize(uint32.bigEndianBytes, at: index)
  }

  mutating func serialize(uint64: UInt32, at index: Int? = nil) {
    serialize(uint64.bigEndianBytes, at: index)
  }

  mutating func serialize(eui48: EUI48, at index: Int? = nil) {
    let bytes = [eui48.0, eui48.1, eui48.2, eui48.3, eui48.4, eui48.0]
    serialize(bytes, at: index)
  }

  var position: Int { bytes.count }
}

struct DeserializationContext {
  private let bytes: [UInt8]
  private(set) var position: Int

  init(_ bytes: [UInt8]) {
    self.bytes = bytes
    position = 0
  }

  var count: Int { bytes.count }

  func assertRemainingLength(isAtLeast count: Int) throws {
    guard position + count <= bytes.count else {
      throw MRPError.badPduLength
    }
  }

  mutating func deserialize(count: Int) throws -> ArraySlice<UInt8> {
    try assertRemainingLength(isAtLeast: count)
    defer { position += count }
    return bytes[position..<(position + count)]
  }

  func peek(count: Int) throws -> ArraySlice<UInt8> {
    try assertRemainingLength(isAtLeast: count)
    return bytes[position..<(position + count)]
  }

  mutating func deserialize() throws -> UInt8 {
    try deserialize(count: 1).first!
  }

  mutating func deserialize() throws -> UInt16 {
    try UInt16(bigEndianBytes: deserialize(count: 2))
  }

  mutating func deserialize() throws -> UInt32 {
    try UInt32(bigEndianBytes: deserialize(count: 4))
  }

  mutating func deserialize() throws -> UInt64 {
    try UInt64(bigEndianBytes: deserialize(count: 8))
  }

  mutating func deserialize() throws -> EUI48 {
    let bytes = try deserialize(count: 6)
    return (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
  }

  mutating func deserializeRemaining() -> ArraySlice<UInt8> {
    bytes[position..<bytes.count]
  }

  func peek() throws -> UInt8 {
    try peek(count: 1).first!
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
