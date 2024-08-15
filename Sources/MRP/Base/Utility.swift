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

struct Weak<T: AnyObject> {
  weak var object: T?

  init(_ object: T) {
    self.object = object
  }
}

extension Weak: Sendable where T: Sendable {}

extension Weak: Equatable where T: Equatable {
  static func == (lhs: Weak<T>, rhs: Weak<T>) -> Bool {
    lhs.object == rhs.object
  }
}

// https://stackoverflow.com/questions/25329186/safe-bounds-checked-array-lookup-in-swift-through-optional-bindings
extension Collection {
  /// Returns the element at the specified index if it is within bounds, otherwise nil.
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

// https://www.swiftbysundell.com/articles/async-and-concurrent-forEach-and-map/
public extension Sequence {
  func asyncMap<T>(
    _ transform: (Element) async throws -> T
  ) async rethrows -> [T] {
    var values = [T]()

    for element in self {
      try await values.append(transform(element))
    }

    return values
  }

  func asyncCompactMap<T>(
    _ transform: (Element) async throws -> T?
  ) async rethrows -> [T] {
    var values = [T]()

    for element in self {
      if let transformed = try await transform(element) {
        values.append(transformed)
      }
    }

    return values
  }
}

extension Int {
  static func ceil(_ numerator: Self, _ demominator: Self) -> Self {
    (numerator + (demominator - 1)) / demominator
  }
}
