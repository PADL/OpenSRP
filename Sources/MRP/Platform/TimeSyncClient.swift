//
// Copyright (c) 2026 PADL Software Pty Ltd
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

#if os(Linux)

import gPTP2d
import PMC

// The 802.1AS state MRP needs from the local gPTP daemon, keyed by interface name: per-port
// asCapable (35.2.1) and meanLinkDelay (term d of srpPortTcMaxLatency, 35.2.2.8.6). Everything
// else either daemon exposes -- ptp4l's port data sets, gptp2d's clock and statistics data --
// is outside this interface, as mrpd has no use for it.
public protocol TimeSyncClient: Sendable {
  func isAsCapable(interface: String) async throws -> Bool
  // 802.1AS neighborPropDelay in nanoseconds. Throws MRPError.ptpNotReady before the first
  // pdelay exchange has yielded a measurement; callers treat that as provisional, not as zero.
  func meanLinkDelayNs(interface: String) async throws -> Int
}

// The gPTP daemon mrpd queries for asCapable and peer delay.
public enum TimeSyncBackend: String, Sendable, CaseIterable {
  case ptp4l
  case gptp2d
}

func makeTimeSyncClient(
  _ backend: TimeSyncBackend,
  path: String?
) async throws -> any TimeSyncClient {
  switch backend {
  case .ptp4l: try await PTPTimeSyncClient(path: path)
  case .gptp2d: try await GPTP2dTimeSyncClient(path: path)
  }
}

// ptp4l, over the PTP management (PMC) socket. PMC addresses ports by number, so the interface
// name is resolved once via PORT_PROPERTIES_NP and cached.
private actor PTPTimeSyncClient: TimeSyncClient {
  private let _pmc: PTPManagementClient
  private var _portNumbers = [String: UInt16]()

  init(path: String?) async throws {
    _pmc = try await PTPManagementClient(path: path)
  }

  private func _portNumber(for interface: String) async throws -> UInt16 {
    if let portNumber = _portNumbers[interface] { return portNumber }
    let defaultDataSet = try await _pmc.getDefaultDataSet()
    for portNumber in 1...defaultDataSet.numberPorts {
      if let portProperties = try? await _pmc.getPortPropertiesNP(portNumber: portNumber),
         portProperties.interface.description == interface
      {
        _portNumbers[interface] = portNumber
        return portNumber
      }
    }
    throw PTP.Error.unknownPort
  }

  func isAsCapable(interface: String) async throws -> Bool {
    let portNumber = try await _portNumber(for: interface)
    return try await _pmc.getPortDataSetNP(portNumber: portNumber).asCapable != 0
  }

  func meanLinkDelayNs(interface: String) async throws -> Int {
    let portNumber = try await _portNumber(for: interface)
    // PTP timeinterval is ns * 2^16; a negative value is ptp4l's not-yet-measured sentinel.
    let meanLinkDelay = try await _pmc.getPortDataSet(portNumber: portNumber).meanLinkDelay
    guard meanLinkDelay >= 0 else { throw MRPError.ptpNotReady }
    return Int(meanLinkDelay >> 16)
  }
}

// excelfore gptp2d, over its IPC socket. gptp2d keys ports by name natively and reports
// neighborPropDelay in nanoseconds, so both reads are a single round trip.
private actor GPTP2dTimeSyncClient: TimeSyncClient {
  private let _gptp2d: GPTP2dClient

  init(path: String?) async throws {
    _gptp2d = try await GPTP2dClient(path: path)
  }

  func isAsCapable(interface: String) async throws -> Bool {
    try await _gptp2d.portInfo(interface: interface).asCapable
  }

  func meanLinkDelayNs(interface: String) async throws -> Int {
    // gptp2d leaves neighborPropDelay at 0 until a pdelay exchange completes; it has no
    // negative sentinel, so zero is the not-yet-measured case.
    let neighborPropDelayNs = try await _gptp2d.portInfo(interface: interface).neighborPropDelayNs
    guard neighborPropDelayNs > 0 else { throw MRPError.ptpNotReady }
    return Int(neighborPropDelayNs)
  }
}

#endif
