#!/usr/bin/env bash
# Build the iproute2 .deb (ip/tc/bridge/...) from the PADL fork, cross-compiled
# for arm64. The brport-filter-stream-reserved branch carries the patched
# `bridge` needed by the SRP stream-reserved port filtering.
#
# This package is named "iproute2" and replaces the stock distro package.
set -euo pipefail
. "$(dirname "$0")/common.sh"

src="$(git_checkout iproute2 "$IPROUTE2_GIT" "$IPROUTE2_REF")"

VER="$(resolve_version "$src" "${IPROUTE2_BASE_VERSION:-7.0.0}")"
msg "Building iproute2 (arm64) version $VER"

# configure enables libmnl/libelf/libselinux from the (arch-independent) host
# headers, so the build needs the matching arm64 libraries to link against.
# Supply them from ports.ubuntu.com into a local overlay (incl. transitive deps
# for -rpath-link resolution); nothing from the host sysroot is used.
overlay="$WORK_DIR/iproute2-sysroot"
rm -rf "$overlay"; mkdir -p "$overlay"
# libelf1 was renamed libelf1t64 in noble (64-bit time_t transition).
fetch_arm64_debs "$overlay" \
  libmnl0 libmnl-dev libelf1t64 libelf-dev libselinux1 libselinux1-dev \
  zlib1g libzstd1 libpcre2-8-0
LIBDIR="$overlay/usr/lib/aarch64-linux-gnu"

# HOSTCC=gcc: netem builds small table generators that are *run* at build time,
# so they must target the host, not arm64 (the makefile defaults HOSTCC to CC).
( cd "$src"
  CC="${CROSS_COMPILE}gcc" ./configure
  make CC="${CROSS_COMPILE}gcc" HOSTCC=gcc clean >/dev/null 2>&1 || true
  make CC="${CROSS_COMPILE}gcc" HOSTCC=gcc \
    LDFLAGS="-L$LIBDIR -Wl,-rpath-link,$LIBDIR" -j"$(nproc)"
)

stage="$WORK_DIR/iproute2"
rm -rf "$stage"; mkdir -p "$stage"
# Default config files install under /usr/share/iproute2 (not /etc), so there
# are no conffiles to declare.
make -C "$src" install CC="${CROSS_COMPILE}gcc" HOSTCC=gcc \
  DESTDIR="$stage" PREFIX=/usr SBINDIR=/usr/sbin MANDIR=/usr/share/man

msg "iproute2 'bridge' shared-library dependencies (NEEDED):"
"${CROSS_COMPILE}objdump" -p "$stage/usr/sbin/bridge" 2>/dev/null | awk '/NEEDED/{print "    "$2}'

# Runtime deps from NEEDED across ip/tc/bridge/dcb/devlink (libelf1t64 is the
# noble name for libelf1).
build_deb iproute2 "$VER" "$stage" \
  "libc6, libmnl0, libelf1t64, libselinux1" \
  "PADL iproute2 (ip, tc, bridge) with stream-reserved brport filtering"
