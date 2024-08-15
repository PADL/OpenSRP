//
// Copyright (c) 2019, Intel Corporation
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

private let AAF_OVERHEAD = 24 // AVTP stream header
private let VLAN_OVERHEAD = 4 // VLAN tag
private let L2_OVERHEAD = 18 // Ethernet header + CRC
private let L1_OVERHEAD = 20 // Preamble + frame delimiter + interpacket gap

private func calcClassACredits(
  idleslopeA: Int,
  sendslopeA: Int,
  linkSpeed: Int,
  frameNonSr: Int,
  maxFrameSizeA: Int
) -> (Int, Int) {
  // According to 802.1Q-2014 spec, Annex L, hiCredit and
  // loCredit for SR class A are calculated following the
  // equations L-10 and L-12, respectively.
  let hicredit = Int(ceil(Double(idleslopeA) * Double(frameNonSr) / Double(linkSpeed)))
  let locredit = Int(ceil(Double(sendslopeA) * Double(maxFrameSizeA) / Double(linkSpeed)))
  return (hicredit, locredit)
}

private func calcClassBCredits(
  idleslopeA: Int,
  idleslopeB: Int,
  sendslopeB: Int,
  linkSpeed: Int,
  frameNonSr: Int,
  maxFrameSizeA: Int,
  maxFrameSizeB: Int
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

private func calcFrameSize(packetSize: Int) -> Int {
  packetSize + AAF_OVERHEAD + VLAN_OVERHEAD + L2_OVERHEAD + L1_OVERHEAD
}

private func calcSrClassParams(packetSize: Int, packetRate: Int) -> (Int, Int) {
  var idleslope = 0
  var maxFrameSize = 0
  let frameSize = calcFrameSize(packetSize: packetSize)
  idleslope += packetRate * frameSize * 8 / 1000
  maxFrameSize = max(maxFrameSize, frameSize)
  return (maxFrameSize, Int(ceil(Double(idleslope))))
}

//   func updateCBS(idleSlope: Int, sendSlope: Int, hiCredit: Int, loCredit: Int) async throws

extension MSRPAwareBridge {
  func updateCBS(
    port: P,
    packetParameters: [SRclassID: (Int, Int)]
  ) async throws {}
}

extension Port {}

//   func updateCBS(queueID: Int, idleSlope: Int, sendSlope: Int, hiCredit: Int, loCredit: Int)
//   async throws
