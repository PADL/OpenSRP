//
// Copyright (c) 2025 PADL Software Pty Ltd
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

#if canImport(FlyingFox)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FlyingFox

func _getSnakeCaseJSONEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .prettyPrinted
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.dateEncodingStrategy = .secondsSince1970
  encoder.dataEncodingStrategy = .base64
  return encoder
}

extension URL {
  /// Generic path parameter extractor with validation
  func extractParameter<T>(
    after keyword: String,
    as type: T.Type,
    validator: (String) -> T?
  ) -> (T, URL)? {
    let components = pathComponents
    guard let keywordIndex = components.firstIndex(of: keyword),
          keywordIndex + 1 < components.count else { return nil }

    let parameterString = components[keywordIndex + 1]
    guard let parameter = validator(parameterString) else { return nil }

    // Build residual URL more efficiently
    let residualComponents = Array(components.dropFirst(keywordIndex + 2))
    let residualPath = "/" + residualComponents.joined(separator: "/")
    guard let residualURL = URL(string: residualPath) else { return nil }

    return (parameter, residualURL)
  }

  /// Optimized path component extraction
  func getComponentPrecededBy(_ string: String) -> (String, URL)? {
    extractParameter(after: string, as: String.self) { $0 }
  }
}

#endif
