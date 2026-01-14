#!/bin/sh

BR=br0
HANDLE=9000

for INDEX in p4 s8s0
do
	ETH="en${INDEX}"
	echo "Unconfiguring ${ETH} Qdisc..."

	tc qdisc del dev ${ETH} parent root handle ${HANDLE} mqprio
	echo "${ETH} unconfigured\n"
done

set -e

echo "Configuring customer bridge MRP group address forwarding"

nft delete table bridge nat || : >/dev/null 2>&1

#ip link set dev ${BR}.50 type vlan mvrp on
#ip link set dev ${BR}.51 type vlan mvrp on

nft add table bridge nat
nft add chain bridge nat PREROUTING { type filter hook prerouting priority dstnat\; policy accept\; }

# note we don't need to drop LLDP because it's not forwarded by the bridge,
# whereas the MMRP/MVRP multicast address is (we need to intercept it)
nft add rule bridge nat PREROUTING meta ibrname ${BR} ether daddr 01:80:c2:00:00:21 log group 10 drop
nft list ruleset

echo ""

# https://tsn.readthedocs.io/qdiscs.html

for INDEX in p4 s8s0
do
	ETH="en${INDEX}"
	echo "Configuring ${ETH} Qdisc..."

	tc qdisc del dev ${ETH} parent root handle ${HANDLE} || : >/dev/null 2>&1
	tc qdisc add dev ${ETH} parent root handle ${HANDLE} mqprio \
		num_tc 3 \
		map 0 0 1 2 0 0 0 0 0 0 0 0 0 0 0 0 \
		queues 2@2 1@1 1@0 \
		hw 1

	echo "${ETH} configured!\n"
done
