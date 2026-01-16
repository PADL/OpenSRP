#!/bin/sh

# if you're using a systemd that's too old to support L2 BridgeMDB entries, you can use this script

INTERFACES=${1:-"br0 xe0 lan1"}

echo -n "Configuring bridge MDB for AVB..."

for interface in $INTERFACES; do
    bridge mdb add dev br0 port $interface grp 91:e0:f0:01:00:00 permanent
    bridge mdb add dev br0 port $interface grp 91:e0:f0:01:00:01 permanent
    bridge mdb add dev br0 port $interface grp 91:e0:f0:00:ff:00 permanent
done

echo "done!"

bridge mdb
