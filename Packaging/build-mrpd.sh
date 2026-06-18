#!/usr/bin/env bash
# Build the mrpd .deb (Swift, arm64, release, statically-linked Swift stdlib).
# Produces /usr/sbin/mrpd plus the portmon and pmctool helpers.
set -euo pipefail
. "$(dirname "$0")/common.sh"

cd "$SWIFTMRP_DIR"

# The cross SDK (6.3-RELEASE) was built with Swift 6.3; a different default
# compiler (e.g. 6.3.2) cannot import its stdlib. Build with a matching
# swiftly toolchain. Override the version with SWIFT_TOOLCHAIN.
SWIFT_TOOLCHAIN="${SWIFT_TOOLCHAIN:-6.3.0}"
tc_bin="$HOME/.local/share/swiftly/toolchains/$SWIFT_TOOLCHAIN/usr/bin"
if [ -d "$tc_bin" ]; then
  export PATH="$tc_bin:$PATH"
else
  warn "toolchain $SWIFT_TOOLCHAIN not found at $tc_bin; using default swift"
fi
msg "swift: $(command -v swift) — $(swift --version 2>/dev/null | head -1)"

VER="$(resolve_version "$SWIFTMRP_DIR" "${MRPD_BASE_VERSION:-0.1.0}")"
msg "Building mrpd (Swift / arm64 / release / static stdlib) version $VER"

swift build -c release \
  --swift-sdk "$SWIFT_SDK" \
  --traits RestAPI --static-swift-stdlib

BIN="$(swift build -c release --swift-sdk "$SWIFT_SDK" --show-bin-path)"

stage="$WORK_DIR/mrpd"
rm -rf "$stage"; mkdir -p "$stage"
install -D -m0755 "$BIN/mrpd"    "$stage/usr/sbin/mrpd"
install -D -m0755 "$BIN/portmon" "$stage/usr/bin/portmon"
install -D -m0755 "$BIN/pmctool" "$stage/usr/bin/pmctool"
# NetLinkSwift diagnostic tools (built as mrpd target deps; see Package.swift
# PlatformTargetDependencies). Useful on the target for inspecting bridge/VLAN/
# FDB/MDB state, e.g. nlmonitor to watch RTM_NEWVLAN notifications.
install -D -m0755 "$BIN/nlmonitor" "$stage/usr/bin/nlmonitor"
install -D -m0755 "$BIN/nldump"    "$stage/usr/bin/nldump"
install -D -m0755 "$BIN/nltool"    "$stage/usr/bin/nltool"
# mrp: Python CLI that interrogates the mrpd REST API (needs the RestAPI trait).
install -D -m0755 "$SWIFTMRP_DIR/Tools/mrp" "$stage/usr/bin/mrp"

# Strip symbols/debug info — static Swift stdlib makes these binaries ~50M each
# otherwise. Use the cross strip so it understands arm64 objects.
for b in usr/sbin/mrpd usr/bin/portmon usr/bin/pmctool \
         usr/bin/nlmonitor usr/bin/nldump usr/bin/nltool; do
  "${CROSS_COMPILE}strip" --strip-unneeded "$stage/$b"
done
install -D -m0644 "$SWIFTMRP_DIR/Configs/mrpd.service" \
  "$stage/lib/systemd/system/mrpd.service"
# avb.target groups the stack; referenced (PartOf=) by mrpd and ptp4l.
install -D -m0644 "$SWIFTMRP_DIR/Configs/avb.target" \
  "$stage/lib/systemd/system/avb.target"
# Shared bridge/interface configuration sourced by mrpd.service and ptp4l.service.
install -D -m0644 "$SWIFTMRP_DIR/Configs/avb.default" "$stage/etc/default/avb"

# /etc/default/avb is configuration — preserve local edits across upgrades.
install -d "$stage/DEBIAN"
echo /etc/default/avb > "$stage/DEBIAN/conffiles"

msg "mrpd shared-library dependencies (NEEDED) — verify these exist on target:"
"${CROSS_COMPILE}objdump" -p "$BIN/mrpd" | awk '/NEEDED/{print "    "$2}'

# Runtime deps from the binary's NEEDED libs (see objdump output above) plus
# nftables + iproute2, which are invoked from mrpd.service (nft, bridge).
build_deb mrpd "$VER" "$stage" \
  "libc6, libstdc++6, libgcc-s1, liburing2, libsystemd0, libnl-3-200, libnl-route-3-200, libnl-nf-3-200, libcurl4t64, nftables, iproute2, python3, python3-requests" \
  "OpenSRP MRP/MVRP/MSRP daemon (mrpd) with portmon and pmctool helpers" \
  mrpd.service avb.target
