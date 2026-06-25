# Avnu ProAV Bridge Specification compliance items

Note: some of the git hashes may have changed owing to rebasing during
development. However if you see a git hash, you can assume the item has been
completed. Items annotated with a branch name (rather than a hash) are still
in progress on that branch and not yet merged to main.

## Open TODOs, prioritised

Priority is judged by Avnu-certification readiness and on-wire robustness for the
constrained switch appliance (P1 highest). Each TODO below is tagged inline.

Resolved on branch `avnu-todo-p1-p3`: §8.1 malformed-PDU parsing (P1, fixed); §5
gPTP-independence and §9.1 ≤1.5s propagation (P2, verified already-compliant);
§8.1 leave-on-blocked-port (P2, already compliant — see §8.1 below). Remaining:

* **P3** — §8.1 New=TRUE on tcDetected and the §10 "only Dynamic Filtering Entries
  removed on New" that depends on it: low value here — the kernel flushes the FDB
  on a topology change anyway and mstpd does not notify. See
  [[reference_mrp_tcdetected_new_marking]].
* **P3** — §10 Registration Fixed/Forbidden: a static-configuration feature this
  appliance does not use; defer unless a deployment needs it.

# 5 General requirements

* NA: physical transport — copper BASE-T or fiber BASE-FX/SX/BX/LX, min 100Mbps full-duplex (link/hardware)
* DONE: MSRP Domain declaration on a port does not depend on that port's gPTP
  state. Verified: `_declareDomain`/`_declareDomains` run on context add/update for
  every port and consult only the port's SR-class priority mapping and the prior
  declared value — no asCapable/gPTP check (the code comment notes Domain is a
  local per-port announcement, never blocked per 35.1.3.1). The only gPTP coupling,
  `_checkAsCapable`, gates Talker/Listener join/leave indications, not Domain, and
  is off by default (`.ignoreAsCapable` is in `defaultFlags`).

# 6 CBS

* NA: implement the Credit Based Shaper (802.1Q Clause 34) — hardware shaper
* c0b74d4: support SR Class A and SR Class B (`SRclassID` .A/.B throughout — per-class queues, delta bandwidths, domain declaration and CBS params; default maxSRClass .B)
* NA: on a non-boundary port, filter a frame carrying an SR class priority when
  its destination MAC is not one used by a reserved stream — a datapath concern
  outside OpenSRP scope. Handled by the Marvell switch in enhanced AVB mode, or in
  the software bridge via the TC flower `dynamic_reservation_hit` match (WIP
  kernel work, PADL/linux@e8f78bb2a8d11b02c7450800cb72a39c57608615). See
  [[reference_mv88e6xxx_bad_avb_no_reservation]]
* msrp-dcb-pcp-frame-priority (5a9bd39): SRP domain boundary-port priority
  regeneration override (802.1Q Cl.6.9.4, default values Table 6-5) — map ingress
  PCP to frame priority, not queue. See [[reference_dcb_pcp_fpri]]
* NA (datapath): boundary-port priority regeneration (802.1Q Cl.6.9.4). At an SRP
  domain **boundary** port, a received frame bearing an SR class priority (by
  default PCP 3 = Class A, 2 = Class B) is not genuine stream traffic, so Cl.6.9.4
  regenerates its PCP to **0** (this should be configurable). DCB cannot do this —
  it maps PCP→**queue**, not the PCP value — so it is a datapath concern outside
  OpenSRP. It is effectively subsumed by the same capability as the SR-priority
  filter above: on the Marvell switch in enhanced AVB mode, and in the software
  bridge via `dynamic_reservation_hit`, we already remap AVB-priority frames that
  have no FDB (reserved-stream) entry, from any port. That keys on reservation
  presence (per-stream) rather than `SRPdomainBoundaryPort` (per-port), which is
  finer-grained and achieves the same goal — non-reserved AVB-priority traffic is
  demoted regardless of boundary status, so no per-boundary regeneration table
  reprogramming is needed. See [[reference_mv88e6xxx_bad_avb_no_reservation]],
  [[reference_dcb_pcp_fpri]]. (Aside: the SRP clause §35.2.4.3 only defines the
  boundary as a Talker-Advertise→Talker-Failed code-8 conversion; the priority
  *remapping* lives in Cl.6.9.4, not the SRP excerpt.)

# 7 gPTP

* NA: gPTP (§7.1–7.7: Pdelay accuracy, scaledLastGmFreqChange, asCapable, message
  intervals/timeouts, negative-pdelay handling) is provided by the external gPTP
  daemon (linuxptp), not SwiftMRP.

# 8 MRP

## 8.1 General

* ca011b8: EndMark/End of PDU is serialized as 0x0000 (PDU.swift `EndMark`), so no PAD ever follows a literal "End of PDU"
* TODO (P3): set New to TRUE on MAD\_Join.{indications,requests} after topology change (tcDetected). See [[reference_mrp_tcdetected_new_marking]]
* DONE: leave events are transmitted from a port while it is not in the Forwarding state. The 35.1.3.1 gating only suppresses *new* declarations (joins) on a blocked port; withdrawals are not gated. When a port goes non-Forwarding the recompute's withdraw sweep (`_applyStreamPlan`, via `apply(for:)` over *all* participants regardless of STP state) leaves any actively-declared attribute, and the applicant `Lv` path (QA/AA → LA → `sL`) transmits the Leave on the next tx opportunity — and neither the sweep nor the tx path (`Participant._tx`) checks Forwarding state, so the Leave goes out the blocked port. A *passively* declared attribute (applicant VP, never announced) correctly emits no Leave (`Lv`: VP → VO) — you do not Leave what you never Joined on the wire. So §8.1 is satisfied by existing behaviour; no separate "propagate on blocked port" path is needed.
* DONE: for each registered Talker attribute, a corresponding Listener attribute can be registered on all ports — satisfied by the per-stream propagation model (Talker propagates to other ports, Listener declarations merge toward the talker), not auto-generated
* DONE: badly formed PDUs are parsed up to the bad octet — the MRPDU message loop keeps the messages parsed before a corrupted/truncated field and discards the remainder (a structural MRPError or the BinaryParsing buffer overrun both break-and-keep, rather than discarding the whole PDU). Forward-compat unknown-attribute skipping on a higher protocol version is preserved. Locked in by testMalformedPduKeepsValidPrefix

## 8.2 MRP timer values

* 7cab55c8: update MRP timer values

## 8.3 Applicant State Machine

* de2848e0: ignore transition to LO from VO/AO/QO when receiving rLA!, txLA!, or txLAF!

## 8.4: Registrar State Machine

* DONE: a "Lv" shall occur when in the STATE "IN" when the EVENT "Flush!" occurs.

# 9 MSRP

## 9.1 General

* f412134b: validate MaxIntervalFrames != 0
* DONE: disable Talker pruning
* DONE: MSRP attributes propagate within 1.5s. A fresh declaration requests a TX opportunity immediately — interval `.zero` on a point-to-point port (rate-limited to 3 per joinTime×1.5), else random `0..<joinTime` (≤240ms Avnu max); nothing waits on the periodic (1s, disabled per 80272d31) or leaveall (10s) timer. Locked in by testMSRPPropagationCompletesWithin1500ms (propagates in ~13ms)
* 5e7aca0: always declare SR Class A and B Domain on each port regardless of the peer (`_declareDomains` on context add/update)
* DONE: include VLAN tag in bandwidth calculation
* 80272d31: check periodic state machine disabled per 5.4.4 in 802.1Q
* 1e39019: proxy MSRP Talker leave requests from listener to talker
* msrp-preemption-proxy-leave (ff4e7a7): a stream shall not be cancelled
  unnecessarily — when admitting a higher-importance stream would exceed the egress
  port budget, preempt the youngest (least important) reserved streams first, and
  keep any stream that need not be cancelled. Rank-based (Emergency, Rank bit reset,
  outranks Non-emergency); preempted talkers declare streamPreemptedByHigherRank.
* msrp-preemption-proxy-leave (ff4e7a7): an Emergency stream (Rank reset) must
  propagate as a Talker Advertise over lower-importance non-emergency traffic when
  the reservation could be satisfied by dropping streams of lower importance.

## 9.2 Instantaneous transition from IN to MT

* 7e13c66: transition IN / rLv! → (Lv) → MT (gated per-application by the MSRP `leaveImmediate` flag, default on; clearing it falls back to the base 802.1Q leavetimer for peers that do not use the Avnu 5s LeaveTime)

## 9.3 Talker attribute registration

* 2465ff6: limit talker attributes to 150 across all ports — `onJoinIndication` throws `doNotPropagateAttribute` once `_isMaxTalkerAttributesRegistered` (default 150) is reached

# 10 MVRP

* NA: minimum 16 VLANs
* NA: enable ingress filtering by default
* NA: C-VLAN bridge by default
* TODO (P3): only Dynamic Filtering Entries shall be removed when new is received — not wired; `isNew` is logged but unused in MVRPApplication ("TODO: flush FDB entries following a topology change, if isNew is true"). Depends on the §8.1 tcDetected New-marking
* TODO (P3, not an Avnu mandate): Registration Fixed/Forbidden. Avnu §10 does not
  require *supporting* it — it only clarifies the indication behaviour **if** the
  802.1Q control is exercised: setting an attribute to Registration Fixed issues a
  MAD_Join.indication, Registration Forbidden a MAD_Leave.indication, and returning
  to NormalRegistration acts as `rLv!` (10.7.5.17). So this is 802.1Q management
  completeness, not a stream/interop requirement; it only bites if the Registrar
  Administrative Control is actually used, which this appliance does not. The
  Registrar SM machinery partly exists (`.registrationForbidden`,
  `.registrationFixedNew{Ignored,Propagated}`), but there is no per-port/VID
  management surface and MVRP `isRegistrationAllowed` always returns true.
