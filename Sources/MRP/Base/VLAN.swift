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

public struct VLAN: Hashable, Sendable, Identifiable, ExpressibleByIntegerLiteral {
  public typealias ID = UInt16
  public typealias IntegerLiteralType = UInt16

  public var id: ID { vid }
  var vid: UInt16

  var contextIdentifier: MAPContextIdentifier {
    MAPContextIdentifier(id: vid)
  }

  public init(id: ID) {
    self.init(vid: id)
  }

  public init(integerLiteral value: UInt16) {
    self.init(vid: value)
  }

  init(vid: UInt16) {
    self.vid = vid
  }

  init(contextIdentifier: MAPContextIdentifier) {
    self.init(vid: contextIdentifier.id)
  }
}

// In-kernel registrars that may advertise a VLAN on the bridge's behalf (e.g.
// the Linux MVRP/GVRP applicants bound to a VLAN netdev with `mvrp`/`gvrp on`).
public struct VLANApplicant: OptionSet, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public static let mvrp = VLANApplicant(rawValue: 1 << 0)
  public static let gvrp = VLANApplicant(rawValue: 1 << 1)
}

// A local VLAN interface gaining, changing, or losing its in-kernel registrar
// flags; distinct from bridge-port VLAN membership (the AF_BRIDGE VLAN database).
public enum VLANApplicantNotification: Sendable {
  case added(VLAN, VLANApplicant)
  case changed(VLAN, VLANApplicant)
  case removed(VLAN)

  public var vlan: VLAN {
    switch self {
    case let .added(vlan, _): vlan
    case let .changed(vlan, _): vlan
    case let .removed(vlan): vlan
    }
  }

  public var applicant: VLANApplicant {
    switch self {
    case let .added(_, applicant): applicant
    case let .changed(_, applicant): applicant
    case .removed: []
    }
  }
}
