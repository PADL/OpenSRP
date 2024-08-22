#!/bin/sh

nft delete table bridge nat >/dev/null 2>&1

set -e

ip link set dev br0.50 type vlan mvrp on
ip link set dev br0.51 type vlan mvrp on

nft add table bridge nat
nft add chain bridge nat PREROUTING { type filter hook prerouting priority dstnat\; policy accept\; }

# note we don't need to drop LLDP because it's not forwarded by the bridge,
# whereas the MMRP/MVRP multicast address is (we need to intercept it)
#nft add rule bridge nat PREROUTING meta ibrname br0 ether daddr { 01:80:c2:00:00:21, 01:80:c2:00:00:0e } log group 10 drop
nft add rule bridge nat PREROUTING meta ibrname br0 ether daddr 01:80:c2:00:00:21 log group 10 drop
nft list ruleset
