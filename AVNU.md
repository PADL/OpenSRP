# Avnu ProAV Bridge Specification compliance items

Note: some of the git hashes may have changed owing to rebasing during
development. However if you see a git hash, you can assume the item has been
completed. Items annotated with a branch name (rather than a hash) are still
in progress on that branch and not yet merged to main.

# 5 General requirements

* NA: physical transport out of scope
* DONE: MSRP Domain declarations do not depend on port's gPTP state

# 6 CBS

* TODO: SRP domain boundary-port priority regeneration: when a port is a
  boundary port, SR classes (typically PCP 2 and 3) should be mapped to
  PCP 0. Can be done with TC flower, but would require extending the TCAM
  support for the Marvell switches. May not be worth it given the switch
  will reprioritize non-AVB packets already (determined by FDB).
* NA: implement the Credit Based Shaper, this is done by the kernel and/or
  switch chip
* NA: filter SR class priorities when destination MACs are not used by reserved
  stream: handled by TC flower `dynamic_reservation_hit` or Marvell switches in
  enhanced mode (both handled by our kernel patches)
* c0b74d4: support SR Class A and SR Class B

# 7 gPTP

* NA: gPTP (§7.1–7.7: Pdelay accuracy, scaledLastGmFreqChange, asCapable, message
  intervals/timeouts, negative-pdelay handling) is provided by the external gPTP
  daemon (linuxptp), not SwiftMRP.

# 8 MRP

## 8.1 General

* TODO (P3): set New to TRUE on MAD\_Join.{indications,requests} `tcDetected`.
* ca011b8: EndMark/End of PDU is serialized as 0x0000
* DONE: leave events are transmitted from a port while it is not in the
  Forwarding state.
* DONE: for each registered Talker attribute, a corresponding Listener attribute
  can be registered on all ports
* DONE: badly formed PDUs are parsed up to the bad octet

## 8.2 MRP timer values

* 7cab55c8: update MRP timer values

## 8.3 Applicant State Machine

* de2848e0: ignore transition to LO from VO/AO/QO when receiving rLA!, txLA!, or txLAF!

## 8.4: Registrar State Machine

* DONE: a "Lv" shall occur when in the STATE "IN" when the EVENT "Flush!" occurs.

# 9 MSRP

## 9.1 General

* TODO: preempt Emergency streams (Rank reset) (msrp-preemption-proxy-leave branch)
* f412134b: validate MaxIntervalFrames != 0
* 5e7aca0: always declare SR Class A and B Domain on each port
* 80272d31: check periodic state machine disabled per 5.4.4 in 802.1Q
* 1e39019: proxy MSRP Talker leave requests from listener to talker
* DONE: include VLAN tag in bandwidth calculation
* DONE: disable Talker pruning
* DONE: MSRP attributes propagate within 1.5s.

## 9.2 Instantaneous transition from IN to MT

* 7e13c66: transition IN / rLv! → (Lv) → MT

## 9.3 Talker attribute registration

* 2465ff6: limit talker attributes to 150 across all ports 

# 10 MVRP

* TODO: only Dynamic Filtering Entries shall be removed when new is received
* TODO: Registration Fixed/Forbidden (optional)
* NA: minimum 16 VLANs
* NA: enable ingress filtering by default
* NA: C-VLAN bridge by default
