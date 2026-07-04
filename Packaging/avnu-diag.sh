#!/usr/bin/env bash
# On-switch diagnostic capture for an AVnu MRP conformance run (2B/2E et al).
#
# The test harness snapshots the switch AFTER the run, so a torn-down
# reservation has already reverted and the journal window often misses the
# failure. Run this ON the DUT just before starting a test and Ctrl-C when
# done: it writes a continuous, UTC-stamped timeline of the dataplane
# reservation state plus mrpd's journal, so the failure window is captured.
#
# For the reservation lifecycle (Talker/Listener/FDB transitions) mrpd must run
# at debug. Once, before the run:
#   sed -i 's/MRPD_OPTS="\(.*\)"/MRPD_OPTS="\1 --log-level debug"/' /etc/default/avb
#   systemctl restart mrpd            # revert + restart to return to --log-level info
#
# NOTE: hardware-forwarded frames never reach the CPU, so tcpdump on a lanN port
# will NOT see the DUT->TS2 stream. The forwarded stream needs a bidirectional
# external tap on the DUT<->TS2 link -- this script cannot substitute for it.
set -euo pipefail

BR="${BR:-br0}"
INTERVAL="${INTERVAL:-1}"
OUT="${1:-/tmp/avnu-diag-$(date -u +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"
echo "capturing to $OUT every ${INTERVAL}s (Ctrl-C to stop)"

grep -q -- '--log-level debug' /proc/"$(pgrep -x mrpd | head -1)"/cmdline 2>/dev/null \
  || echo "WARNING: mrpd is not at --log-level debug; Talker/Listener/FDB detail will be missing"

# follow the whole run's journal (mrpd + kernel dsa) in the background
journalctl -f -o short-precise -u mrpd -k > "$OUT/journal.log" 2>&1 &
JPID=$!
trap 'kill "$JPID" 2>/dev/null; echo; echo "stopped; output in $OUT"' EXIT INT TERM

# one-shot topology
{ echo "== bridge vlan =="; bridge vlan show
  echo "== bridge fdb =="; bridge fdb show; } > "$OUT/topology.txt" 2>&1

# periodic dataplane state, each block UTC-stamped so it lines up with journal.log
while true; do
  ts="$(date -u +%H:%M:%S.%3N)"
  { echo "===== $ts atu-snapshot (DREs = state MC_STATIC_AVB_NRL) ====="
    atu-snapshot 2>&1
    echo "===== $ts bridge mdb ====="
    bridge mdb show 2>&1
    echo "===== $ts tc -s qdisc (cbs/mqprio) ====="
    tc -s qdisc show 2>&1
  } >> "$OUT/dataplane.log"
  sleep "$INTERVAL"
done
