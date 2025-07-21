# Avnu ProAV Bridge Specification compliance items

# 8 MRP

## 8.1 General

* TODO: check EndMark/End of PDU encoding
* TODO: set New to TRUE on MAD\_Join.{indications,requests} after topology change
* TODO: propogate leave events when port not in forwarding state
* TODO: validate badly formed PDUs are parsed until bad octet

## 8.2 MRP timer values

* 7cab55c8: update MRP timer values

## 8.3 Applicant State Machine

* TODO: ignore transition to LO from VO/AO/QO when receiving rLA!, txLA!, or txLAF!

## 8.4: Registrar State Machine

* DONE: a "Lv" shall occur when in the STATE "IN" when the EVENT "Flush!" occurs.

# 9 MSRP

## 9.1 General

* f412134b: validate MaxIntervalFrames != 0
* DONE: disable Talker pruning
* TODO: check MSRP attributes propagated within 1.5s
* TODO: check always declare SR A/B domain
* DONE: include VLAN tag in bandwidth calculation
* TODO: check periodic state machine disabled per 5.4.4 in 802.1Q
* TODO: proxy MSRP Talker leave requests from listener to talker

## 9.2 Instantaneous transition from IN to MT

* 88fdf63d: transition IN / rLv! → (Lv) → MT

## 9.3 Talker attribute registration

* TODO: limit talker attributes to 150 across all ports

# 10 MVRP

* NA: minimum 16 VLANs
* NA: enable ingress filtering by default
* NA: C-VLAN bridge by default
* TODO: check only Dynamic Filtering Entries shall be removed when new is received
* TODO: check Registration Fixed/Forbidden support complies

