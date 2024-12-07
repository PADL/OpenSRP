#!/bin/sh

BR=br0
HANDLE=9000

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

for INDEX in 0 1 2 3
do
	ETH="lan${INDEX}"
	echo "Configuring ${ETH} qdisc..."

	tc qdisc del dev ${ETH} parent root handle ${HANDLE} || : >/dev/null 2>&1
	tc qdisc add dev ${ETH} parent root handle ${HANDLE} mqprio \
		num_tc 3 \
		map 0 0 1 2 0 0 0 0 0 0 0 0 0 0 0 0 \
		queues 2@0 1@2 1@3 \
		hw 1

	# Class A
	tc qdisc replace dev ${ETH} parent ${HANDLE}:4 cbs \
		idleslope 98688 sendslope -901312 hicredit 153 locredit -1389 \
		offload 1

	# Class B
	tc qdisc replace dev ${ETH} parent ${HANDLE}:3 cbs \
		idleslope 3648 sendslope -996352 hicredit 12 locredit -113 \
		offload 1

	echo "${ETH} configured!\n"
done

tc qdisc
