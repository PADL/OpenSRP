#!/bin/sh

BR=br0
HANDLE=9000
INTERFACES=${1:-"lan0 lan1 lan2 lan3"}

set -e

echo "Configuring customer bridge MRP group address forwarding"

ip link set ${BR} up
ip link set ${BR} type bridge vlan_filtering 1

nft delete table bridge nat || : >/dev/null 2>&1

nft add table bridge nat
nft add chain bridge nat PREROUTING { type filter hook prerouting priority dstnat\; policy accept\; }

# note we don't need to drop LLDP because it's not forwarded by the bridge,
# whereas the MMRP/MVRP multicast address is (we need to intercept it)
nft add rule bridge nat PREROUTING meta ibrname ${BR} ether daddr 01:80:c2:00:00:21 log group 10 drop
nft list ruleset

echo ""

for ETH in $INTERFACES; do
	bridge mdb add dev ${BR} port ${ETH} grp 91:e0:f0:00:00:00 permanent
	bridge mdb add dev ${BR} port ${ETH} grp 91:e0:f0:00:00:01 permanent
	bridge mdb add dev ${BR} port ${ETH} grp 91:e0:f0:00:ff:00 permanent
done
