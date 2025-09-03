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
  func getComponentPrecededBy(_ string: String) -> (String, URL)? {
    let components = pathComponents
    for i in 0..<components.count - 1 {
      if components[i] == string {
        let matchedComponent = components[i + 1]
        let residualComponents = Array(components[(i + 2)...])
        let residualPath = "/" + residualComponents.joined(separator: "/")
        guard let residualURL = URL(string: residualPath) else {
          return nil
        }
        return (matchedComponent, residualURL)
      }
    }
    return nil
  }
}

extension MRPController {
  // port IDs are opaque, identifiable, encodable types, so we cannot
  // directly cast one to an integer. instead, loop through all ports looking
  // for one whose string encoding matches.

  func _getPortByStringID(_ id: String) -> P? {
    ports.first(where: { String(describing: $0.id) == id || $0.name == id })
  }

  func getPort(_ url: URL) -> (P, URL)? {
    guard let (portString, residual) = url.getComponentPrecededBy("port") else { return nil }
    guard let port = _getPortByStringID(portString) else { return nil }
    return (port, residual)
  }

  func getPort(_ request: HTTPRequest) -> (P, URL)? {
    guard let url = URL(string: request.path) else { return nil }
    return getPort(url)
  }

  func getVlan(_ url: URL) -> VLAN? {
    guard let (vlan, _) = url.getComponentPrecededBy("vlan") else { return nil }
    guard let vlan = Int(vlan), let vlan = UInt16(exactly: vlan) else { return nil }
    return VLAN(id: vlan)
  }

  func getPortAndVlan(_ request: HTTPRequest) -> (P, VLAN)? {
    guard let (port, residual) = getPort(request) else { return nil }
    guard let vlan = getVlan(residual) else { return nil }
    return (port, vlan)
  }
}

#endif
