#!/bin/sh

BR=br0
ETH_0=enp8s0
ETH_1=ens4
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

# https://tsn.readthedocs.io/qdiscs.html

echo ""
echo "Configuring ${ETH_0} qdisc..."

tc qdisc del dev ${ETH_0} parent root handle ${HANDLE} || : >/dev/null 2>&1
tc qdisc add dev ${ETH_0} parent root handle ${HANDLE} mqprio \
	num_tc 3 \
	map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
	queues 1@0 1@1 2@2 \
	hw 0
tc qdisc replace dev ${ETH_0} parent ${HANDLE}:1 cbs \
	idleslope 98688 sendslope -901312 hicredit 153 locredit -1389 \
	offload 1
tc qdisc replace dev ${ETH_0} parent ${HANDLE}:2 cbs \
        idleslope 3648 sendslope -996352 hicredit 12 locredit -113 \
        offload 1

echo "${ETH_0} configured!\n"

echo "Configuring ${ETH_1} qdisc..."

tc qdisc del dev ${ETH_1} parent root handle ${HANDLE} || : >/dev/null 2>&1
tc qdisc add dev ${ETH_1} parent root handle ${HANDLE} mqprio \
	num_tc 3 \
	map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
	queues 1@0 1@1 2@2 \
	hw 0
tc qdisc replace dev ${ETH_1} parent ${HANDLE}:1 cbs \
	idleslope 98688 sendslope -901312 hicredit 153 locredit -1389 \
	offload 1
tc qdisc replace dev ${ETH_1} parent ${HANDLE}:2 cbs \
        idleslope 3648 sendslope -996352 hicredit 12 locredit -113 \
        offload 1

echo "${ETH_1} configured!\n"

tc qdisc
