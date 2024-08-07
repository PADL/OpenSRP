#!/bin/sh

set -e

ip link set dev br0.100 type vlan mvrp on

nft add table bridge nat
nft add chain bridge nat PREROUTING { type filter hook prerouting priority dstnat\; policy accept\; }
nft add rule bridge nat PREROUTING meta ibrname "mvrp-bridge" ether daddr { 01:80:c2:00:00:21, 01:80:c2:00:00:0e } log group 3 drop

