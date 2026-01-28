//
// Copyright (c) 2019, Intel Corporation
// Portions Copyright (c) 2024, PADL Software Pty Ltd
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
// contributors may be used to endorse or promote products derived from this
// software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS “AS IS”
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.$
//

#if canImport(Darwin)
import Darwin
#endif
#if canImport(Glibc)
import Glibc
#endif

// clause 35.2.2.8.3: An IEEE 802.3 port on a Bridge would also add 42 octets
// of media-specific framing overhead

private let VLAN_OVERHEAD: UInt16 = 4 // VLAN tag
private let L2_OVERHEAD: UInt16 = 18 // Ethernet header + CRC
private let L1_OVERHEAD: UInt16 = 20 // Preamble + frame delimiter + interpacket gap

extension MSRPAwareBridge {
  static func calcClassACredits(
    idleslopeA: Int,
    sendslopeA: Int,
    linkSpeed: Int,
    frameNonSr: Int,
    maxFrameSizeA: UInt16
  ) -> (Int, Int) {
    // According to 802.1Q-2014 spec, Annex L, hiCredit and
    // loCredit for SR class A are calculated following the
    // equations L-10 and L-12, respectively.
    let hicredit = Int(ceil(Double(idleslopeA) * Double(frameNonSr) / Double(linkSpeed)))
    let locredit = Int(ceil(Double(sendslopeA) * Double(maxFrameSizeA) / Double(linkSpeed)))
    return (hicredit, locredit)
  }

  static func calcClassBCredits(
    idleslopeA: Int,
    idleslopeB: Int,
    sendslopeB: Int,
    linkSpeed: Int,
    frameNonSr: Int,
    maxFrameSizeA: UInt16,
    maxFrameSizeB: UInt16
  ) -> (Int, Int) {
    let hicredit = Int(ceil(
      Double(idleslopeB) *
        (
          (Double(frameNonSr) / Double(linkSpeed - idleslopeA)) +
            (Double(maxFrameSizeA) / Double(linkSpeed))
        )
    ))
    let locredit = Int(ceil(Double(sendslopeB) * Double(maxFrameSizeB) / Double(linkSpeed)))
    return (hicredit, locredit)
  }

  private static func calcSrClassParams(
    application: MSRPApplication<P>,
    portState: MSRPPortState<P>,
    streams: [SRclassID: [MSRPTSpec]],
    srClassID: SRclassID
  ) throws -> (UInt16, Int) {
    var idleslope = 0
    var maxFrameSize = UInt16(0)

    for stream in streams[srClassID] ?? [] {
      let (frameSize, bandwidthUsed) = try calculateBandwidthUsed(
        srClassID: srClassID,
        tSpec: stream,
        maxFrameSize: application._latencyMaxFrameSize,
        nominalBandwidth: false
      )
      idleslope += bandwidthUsed
      maxFrameSize = max(maxFrameSize, frameSize)
    }

    return (maxFrameSize, idleslope)
  }

  func adjustCreditBasedShaper(
    application: MSRPApplication<P>,
    port: P,
    portState: MSRPPortState<P>,
    streams: [SRclassID: [MSRPTSpec]]
  ) async throws {
    // If no streams, disable CBS by setting slopes to zero
    if streams.isEmpty {
      for queue in application._queues.values.sorted() {
        try await adjustCreditBasedShaper(
          port: port,
          queue: queue,
          idleSlope: 0,
          sendSlope: 0,
          hiCredit: 0,
          loCredit: 0
        )
      }
      return
    }
    let (maxFrameSizeA, idleslopeA) = try! Self.calcSrClassParams(
      application: application,
      portState: portState,
      streams: streams,
      srClassID: .A
    )
    let sendslopeA = idleslopeA - Int(port.linkSpeed)
    let (hicreditA, locreditA) = Self.calcClassACredits(
      idleslopeA: idleslopeA,
      sendslopeA: sendslopeA,
      linkSpeed: Int(port.linkSpeed),
      frameNonSr: Int(port.mtu),
      maxFrameSizeA: maxFrameSizeA
    )

    if let queueA = application._queues[.A] {
      application._logger
        .trace(
          "MSRP: adjusting CBS for class A: idleSlope: \(idleslopeA) sendSlope: \(sendslopeA) hiCredit: \(hicreditA) loCredit: \(locreditA)"
        )

      try await adjustCreditBasedShaper(
        port: port,
        queue: queueA,
        idleSlope: idleslopeA,
        sendSlope: sendslopeA,
        hiCredit: hicreditA,
        loCredit: locreditA
      )
    }

    let (maxFrameSizeB, idleslopeB) = try! Self.calcSrClassParams(
      application: application,
      portState: portState,
      streams: streams,
      srClassID: .B
    )
    let sendslopeB = idleslopeB - Int(port.linkSpeed)
    let (hicreditB, locreditB) = Self.calcClassBCredits(
      idleslopeA: idleslopeA,
      idleslopeB: idleslopeB,
      sendslopeB: sendslopeB,
      linkSpeed: Int(port.linkSpeed),
      frameNonSr: Int(port.mtu),
      maxFrameSizeA: maxFrameSizeA,
      maxFrameSizeB: maxFrameSizeB
    )

    if let queueB = application._queues[.B] {
      application._logger
        .trace(
          "MSRP: adjusting CBS for class B: idleSlope: \(idleslopeB) sendSlope: \(sendslopeB) hiCredit: \(hicreditB) loCredit: \(locreditB)"
        )

      try await adjustCreditBasedShaper(
        port: port,
        queue: queueB,
        idleSlope: idleslopeB,
        sendSlope: sendslopeB,
        hiCredit: hicreditB,
        loCredit: locreditB
      )
    }
  }
}

func calcFrameSize(_ tSpec: MSRPTSpec) -> UInt16 {
  // Avnu ProAV Bridge specification Section 9.1:
  // transport overhead must include minimum frame size of 68 bytes
  var frameSize = tSpec.maxFrameSize + VLAN_OVERHEAD + L2_OVERHEAD
  if frameSize < 68 {
    frameSize = 68
  }
  return frameSize + L1_OVERHEAD
}

func calculateBandwidthUsed(
  srClassID: SRclassID,
  tSpec: MSRPTSpec,
  maxFrameSize: UInt16,
  nominalBandwidth: Bool
) throws -> (UInt16, Int) {
  var frameSize = calcFrameSize(tSpec)
  if !nominalBandwidth { frameSize += 1 }
  if frameSize > maxFrameSize { frameSize = maxFrameSize }
  let classMeasurementInterval = try srClassID
    .classMeasurementInterval // number of intervals in usec
  let maxFrameRate = Double(tSpec.maxIntervalFrames) *
    (1_000_000.0 / Double(classMeasurementInterval)) // number of frames per second
  let bandwidthUsed = maxFrameRate * Double(frameSize) * 8.0 / 1000.0 // bandwidth used in kbps

  return (frameSize, Int(ceil(bandwidthUsed)))
}
