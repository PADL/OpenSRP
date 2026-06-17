#!/usr/bin/env bash
# Build the mstpd .deb (Multiple Spanning Tree Protocol daemon), cross-compiled
# for arm64. Source is cloned from upstream HEAD.
set -euo pipefail
. "$(dirname "$0")/common.sh"

src="$(git_checkout mstpd "$MSTPD_GIT" "$MSTPD_REF")"

VER="$(resolve_version "$src" "${MSTPD_BASE_VERSION:-0.2.0}")"
msg "Building mstpd (arm64) version $VER"

# mstpd is autotools-based: generate configure, then cross-configure + build.
( cd "$src"
  [ -x configure ] || ./autogen.sh
  ./configure --host="$CROSS_TRIPLE" CC="${CROSS_COMPILE}gcc"
  make clean >/dev/null 2>&1 || true
  make -j"$(nproc)"
)

stage="$WORK_DIR/mstpd"
rm -rf "$stage"; mkdir -p "$stage"
install -D -m0755 "$src/mstpd"   "$stage/usr/sbin/mstpd"
install -D -m0755 "$src/mstpctl" "$stage/usr/sbin/mstpctl"
[ -f "$src/bridge-stp" ] && \
  install -D -m0755 "$src/bridge-stp" "$stage/usr/sbin/bridge-stp"
install -D -m0644 "$SWIFTMRP_DIR/Configs/mstpd.service" \
  "$stage/lib/systemd/system/mstpd.service"

build_deb mstpd "$VER" "$stage" "libc6" \
  "Multiple Spanning Tree Protocol daemon (mstpd) and mstpctl" \
  mstpd.service
