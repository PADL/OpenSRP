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

extension MRPController {
  // port IDs are opaque, identifiable, encodable types, so we cannot
  // directly cast one to an integer. instead, loop through all ports looking
  // for one whose string encoding matches.

  func _getPortByStringID(_ id: String) -> P? {
    ports.first { String(describing: $0.id) == id || $0.name == id }
  }

  // Simplified with new URL extension
  func getPort(_ url: URL) -> (P, URL)? {
    url.extractParameter(after: "port", as: P.self) { _getPortByStringID($0) }
  }

  func getPort(_ request: HTTPRequest) -> (P, URL)? {
    guard let url = URL(string: request.path) else { return nil }
    return getPort(url)
  }

  func getVlan(_ url: URL) -> VLAN? {
    url.extractParameter(after: "vlan", as: VLAN.self) { vlanString in
      guard let vid = UInt16(vlanString) else { return nil }
      return VLAN(id: vid)
    }?.0 // Only return the VLAN, not the residual URL
  }

  // Chain operations more cleanly
  func getPortAndVlan(_ request: HTTPRequest) -> (P, VLAN)? {
    guard let url = URL(string: request.path),
          let (port, residual) = getPort(url),
          let vlan = getVlan(residual) else { return nil }
    return (port, vlan)
  }

  // New: Generic multi-parameter extraction for streams
  func getPortAndStream(_ request: HTTPRequest) -> (P, MSRPStreamID)? {
    guard let url = URL(string: request.path),
          let (port, residual) = getPort(url) else { return nil }

    return residual.extractParameter(
      after: "stream",
      as: MSRPStreamID.self,
      validator: { streamString in
        let streamID = MSRPStreamID(stringLiteral: streamString)
        return streamID != 0 ? streamID : nil
      }
    ).map { (port, $0.0) }
  }
}

#endif
