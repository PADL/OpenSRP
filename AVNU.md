# Avnu ProAV Bridge Specification compliance items

Note: some of the git hashes may have changed owing to rebasing during
development. However if you see a git hash, you can assume the item has been
completed. Items annotated with a branch name (rather than a hash) are still
in progress on that branch and not yet merged to main.

## Open TODOs, prioritised

Priority is judged by Avnu-certification readiness and on-wire robustness for the
constrained switch appliance (P1 highest). Each TODO below is tagged inline.

* **P1** — §8.1 parse badly formed PDUs up to the bad octet, then discard the
  remainder. The one genuine behavioural gap: we currently rethrow on a malformed
  lower-version PDU instead of acting on the good prefix.
* **P2** — §8.1 leave propagation on non-Forwarding ports: resolve whether our
  deliberate 35.1.3.1 gating is acceptable or must yield to the Avnu "may still
  propagate" allowance (design decision, not obviously a bug).
* **P2** — §5 Domain-declaration independence from gPTP, and §9.1 ≤1.5s
  propagation: both are most likely already satisfied; cheap to verify/measure and
  close out.
* **P3** — §8.1 New=TRUE on tcDetected and the §10 "only Dynamic Filtering Entries
  removed on New" that depends on it: low value here — the kernel flushes the FDB
  on a topology change anyway and mstpd does not notify. See
  [[reference_mrp_tcdetected_new_marking]].
* **P3** — §10 Registration Fixed/Forbidden: a static-configuration feature this
  appliance does not use; defer unless a deployment needs it.

# 5 General requirements

* NA: physical transport — copper BASE-T or fiber BASE-FX/SX/BX/LX, min 100Mbps full-duplex (link/hardware)
* TODO (P2): MSRP Domain declaration on a port shall not depend on that port's gPTP
  state (the spec notes gPTP runs its own spanning tree). We gate declarations on
  the bridge spanning-tree Forwarding state (35.1.3.1, e0b30c5), not on gPTP, so
  this should already hold — confirm nothing couples Domain declaration to gPTP.

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

# 7 gPTP

* NA: gPTP (§7.1–7.7: Pdelay accuracy, scaledLastGmFreqChange, asCapable, message
  intervals/timeouts, negative-pdelay handling) is provided by the external gPTP
  daemon (linuxptp), not SwiftMRP.

# 8 MRP

## 8.1 General

* ca011b8: EndMark/End of PDU is serialized as 0x0000 (PDU.swift `EndMark`), so no PAD ever follows a literal "End of PDU"
* TODO (P3): set New to TRUE on MAD\_Join.{indications,requests} after topology change (tcDetected). See [[reference_mrp_tcdetected_new_marking]]
* TODO (P2): propogate leave events when port not in forwarding state — we currently *suppress* declarations on non-Forwarding ports (35.1.3.1 gating, MSRPApplication `isForwarding` guard); Avnu permits leaves to still propagate, so revisit (design decision)
* DONE: for each registered Talker attribute, a corresponding Listener attribute can be registered on all ports — satisfied by the per-stream propagation model (Talker propagates to other ports, Listener declarations merge toward the talker), not auto-generated
* TODO (P1): validate badly formed PDUs are parsed until bad octet — only forward-compat skipping of unknown attribute type/event on a higher protocol version exists today (PDU.swift); a malformed lower-version PDU still rethrows

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
* TODO (P2): check MSRP attributes propagated within 1.5s — timers are configured to support it (periodictimer 900-1500ms, joinTime 180-240ms per MRPTimerConfiguration); no explicit end-to-end 1.5s deadline is modelled
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
* TODO (P3): Registration Fixed/Forbidden support — not implemented; MVRP `isRegistrationAllowed` always returns true. Static-config feature unused by this appliance
