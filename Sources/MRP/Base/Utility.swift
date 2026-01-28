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

extension Array {
  /// Creates an array from a collection, padding to a multiple of the specified value.
  init(_ collection: some Collection<Element>, multiple: Int, with element: Element) {
    let elements = Array(collection)
    let paddingCount = (multiple - elements.count % multiple) % multiple
    self = elements + Array(repeating: element, count: paddingCount)
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

  func asyncReduce<Result>(
    into initialResult: Result,
    _ updateAccumulatingResult: (inout Result, Element) async throws -> ()
  ) async rethrows -> Result {
    var result = initialResult
    for element in self {
      try await updateAccumulatingResult(&result, element)
    }
    return result
  }
}

extension Int {
  static func ceil(_ numerator: Self, _ demominator: Self) -> Self {
    (numerator + (demominator - 1)) / demominator
  }
}
