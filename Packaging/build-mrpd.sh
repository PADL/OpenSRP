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

# Build configuration: "release" (default) or "debug". A debug build is -Onone
# with full debug info and skips the strip step below, for profiling on the
# target with perf. Set NOSTRIP=1 to also keep symbols in a release build
# (release + -g, representative performance) instead. Either way the binaries
# get much larger (static Swift stdlib, unstripped ~70M).
BUILD_CONFIG="${BUILD_CONFIG:-release}"
case "$BUILD_CONFIG" in
  release|debug) ;;
  *) die "BUILD_CONFIG must be 'release' or 'debug', not '$BUILD_CONFIG'" ;;
esac
[ "$BUILD_CONFIG" = debug ] && NOSTRIP=1

VER="$(resolve_version "$SWIFTMRP_DIR" "${MRPD_BASE_VERSION:-0.1.0}")"
# Tag non-release builds so their .deb does not clobber the release artifact.
[ "$BUILD_CONFIG" = release ] || VER="${VER}+${BUILD_CONFIG}"
msg "Building mrpd (Swift / arm64 / $BUILD_CONFIG / static stdlib) version $VER"

# Assemble the swift build flags. The DEFAULT build includes the REST control
# API (FlyingFox + FlyingFoxMacros + AnyCodable, plus their Foundation surface;
# matches avb.default's --rest-server-port). CONSTRAINED=1 targets small-RAM/
# flash devices (e.g. the 64MB switch): it drops the RestAPI trait — removing
# those three packages from the link, ~9.5MB of clean code-page RSS — and builds
# -Osize. On a 1GB box -Osize is pointless (clean text is free/evictable); on a
# 64MB box clean text competes for scarce RAM and is the thrash source, so it
# earns its keep. Runtime memory tuning for the constrained target is layered on
# via a systemd drop-in below, not baked into the shared Configs/mrpd.service.
build_args=(-c "$BUILD_CONFIG" --swift-sdk "$SWIFT_SDK" --static-swift-stdlib)
if [ -n "${CONSTRAINED:-}" ]; then
  msg "CONSTRAINED profile: REST API off, -Osize (small-RAM/flash target)"
  build_args+=(-Xswiftc -Osize)
else
  build_args+=(--traits RestAPI)
fi
# Keep symbols (-g) for perf on debug / NOSTRIP builds. NB: this was previously a
# dangling line after a missing '\', so -g never actually reached swift build.
[ -n "${NOSTRIP:-}" ] && build_args+=(-Xswiftc -g)

swift build "${build_args[@]}"

BIN="$(swift build "${build_args[@]}" --show-bin-path)"

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
# atu-snapshot: Python tool to snapshot/decode the mv88e6xxx switch ATU via
# devlink (only python3 + devlink/iproute2, both already in Depends).
install -D -m0755 "$SWIFTMRP_DIR/Tools/atu-snapshot.py" "$stage/usr/bin/atu-snapshot"

# Strip symbols/debug info — static Swift stdlib makes these binaries ~50M each
# otherwise. Use the cross strip so it understands arm64 objects. Skipped when
# NOSTRIP=1 (debug builds, or release+symbols) so perf can resolve symbols.
if [ -n "${NOSTRIP:-}" ]; then
  msg "NOSTRIP set — keeping symbols; binaries will be large (~70M each)"
else
  for b in usr/sbin/mrpd usr/bin/portmon usr/bin/pmctool \
           usr/bin/nlmonitor usr/bin/nldump usr/bin/nltool; do
    "${CROSS_COMPILE}strip" --strip-unneeded "$stage/$b"
  done
fi
install -D -m0644 "$SWIFTMRP_DIR/Configs/mrpd.service" \
  "$stage/lib/systemd/system/mrpd.service"
# Constrained-target runtime tuning, layered as a systemd drop-in so the shared
# Configs/mrpd.service stays the general profile. Squeezes the dirty side
# further than the committed narenas:2: a single arena, faster decay, and
# thp:never (only effective once the kernel cmdline sets transparent_hugepage=
# madvise|never — on an 'always' system khugepaged collapses regardless), plus a
# smaller io_uring ring. Expect a few MB off Private_Dirty vs the default tuning.
if [ -n "${CONSTRAINED:-}" ]; then
  install -D -m0644 /dev/stdin \
    "$stage/lib/systemd/system/mrpd.service.d/constrained.conf" <<'EOF'
[Service]
# Small-RAM overrides; base settings live in /lib/systemd/system/mrpd.service.
Environment=MALLOC_CONF=narenas:1,background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:0,thp:never
Environment=SWIFT_IORING_QUEUE_ENTRIES=32
EOF
fi
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
  "libc6, libstdc++6, libgcc-s1, liburing2, libsystemd0, libnl-3-200, libnl-route-3-200, libnl-nf-3-200, libcurl4t64, nftables, iproute2, python3, python3-requests, libjemalloc2" \
  "OpenSRP MRP/MVRP/MSRP daemon (mrpd) with portmon and pmctool helpers" \
  mrpd.service avb.target
