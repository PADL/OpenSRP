#!/usr/bin/env bash
# Augment the Swift cross SDK sysroot with the target system libraries that
# mrpd's dependencies require but the stock SDK does not ship:
#
#   liburing   -> IORingSwift (CIORingShims)
#   libsystemd -> swift-systemd (sd_notify, Type=notify units)
#   libnl-3    -> NetLinkSwift (nl-3, nl-route-3, nl-nf-3, nl-genl-3)
#   libcurl    -> FoundationNetworking (dragged in by the RestAPI trait under
#                 static linking). The SDK ships only the static libcurl.a,
#                 whose optional backends (rtmp/gssapi/ssh) have unresolved
#                 symbols; the bundled libcurl.so symlink is dangling. Dropping
#                 the real libcurl.so.4 lets lld link the shared lib instead
#                 (its own deps resolve at runtime, not link time).
#
# Genuine target binaries are downloaded from ports.ubuntu.com and extracted
# into the SDK sysroot. Nothing is taken from the host (amd64) sysroot.
#
# Two SDK shapes are handled, keyed off DEB_ARCH:
#   arm64 — a modern artifactbundle SDK under ~/.swiftpm/swift-sdks; its sysroot
#           is user-writable, so we extract straight into it. Needs libcurl
#           (the default build ships the RestAPI trait).
#   armhf — the legacy swift-embedded-linux/armhf-debian SDK under /opt, selected
#           at build time via SWIFT_DESTINATION_JSON. Its sysroot already bundles
#           libsystemd, and the armhf target is CONSTRAINED (REST off) so libcurl
#           is not needed. /opt is not user-writable, so we stage into $WORK_DIR
#           and `sudo cp` the tree in (the one privileged step).
#
# Idempotent: re-running just re-extracts. Override the package set with
# SYSROOT_PKGS, the mirror with PORTS_MIRROR, the suite with UBUNTU_SUITE, or the
# sysroot location with SYSROOT.
set -euo pipefail
. "$(dirname "$0")/common.sh"

# ---- package set (per arch) ---------------------------------------------
# armhf is the constrained (REST-off) target: no libcurl, and libsystemd is
# already in the SDK sysroot. arm64 keeps both for the RestAPI trait.
case "$DEB_ARCH" in
  # linux-libc-dev: the armhf-debian SDK bundles bookworm's kernel uapi headers
  # (kernel ~6.1), but we drop in noble's liburing 2.5, whose inline helpers
  # reference newer uapi (e.g. IORING_MSG_RING_FLAGS_PASS). liburing's bundled
  # <liburing/io_uring.h> shares an include guard with the system
  # <linux/io_uring.h>, so the older system header wins and the macro goes
  # undefined. Overlaying noble's linux-libc-dev brings the uapi up to match
  # (the arm64 noble SDK already ships these headers). glibc stays bookworm --
  # kernel uapi and glibc version independently.
  armhf) _pkgs_default="linux-libc-dev liburing2 liburing-dev \
    libnl-3-200 libnl-3-dev libnl-route-3-200 libnl-route-3-dev \
    libnl-nf-3-200 libnl-nf-3-dev libnl-genl-3-200 libnl-genl-3-dev" ;;
  *)     _pkgs_default="liburing2 liburing-dev libsystemd0 libsystemd-dev \
    libnl-3-200 libnl-3-dev libnl-route-3-200 libnl-route-3-dev \
    libnl-nf-3-200 libnl-nf-3-dev libnl-genl-3-200 libnl-genl-3-dev \
    libcurl4t64" ;;
esac
PKGS="${SYSROOT_PKGS:-$_pkgs_default}"

# ---- locate the sysroot -------------------------------------------------
# armhf (or any --destination JSON SDK): read the "sdk" path out of the JSON.
# arm64: find the *.sdk dir inside the artifactbundle named by SWIFT_SDK.
if [ -n "${SYSROOT:-}" ]; then
  : # caller pinned it (e.g. for testing)
elif [ "$DEB_ARCH" = armhf ] || [ -n "${SWIFT_DESTINATION_JSON:-}" ]; then
  json="${SWIFT_DESTINATION_JSON:-/opt/swift-6.3.2-RELEASE-debian-bookworm-armv7/debian-bookworm-static.json}"
  [ -f "$json" ] || die "destination JSON not found: $json (set SWIFT_DESTINATION_JSON)"
  SYSROOT="$(sed -n 's/.*"sdk"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json" | head -1)"
  [ -n "$SYSROOT" ] || die "could not read \"sdk\" path from $json"
else
  SDK_BUNDLE="$HOME/.swiftpm/swift-sdks/${SWIFT_SDK}.artifactbundle"
  SYSROOT="$(find "$SDK_BUNDLE" -maxdepth 4 -type d -name '*.sdk' 2>/dev/null | head -1)"
  [ -n "$SYSROOT" ] || die "could not locate sysroot under $SDK_BUNDLE"
fi
[ -d "$SYSROOT" ] || die "sysroot does not exist: $SYSROOT"
msg "augmenting sysroot: $SYSROOT"

# ---- download + extract the target packages into the sysroot ------------
# If the sysroot is writable extract straight in; otherwise (the /opt SDK)
# stage into $WORK_DIR and copy the tree in with one sudo step.
if [ -w "$SYSROOT/usr" ]; then
  fetch_ports_debs "$SYSROOT" $PKGS
else
  msg "sysroot not writable; staging then installing with sudo"
  overlay="$WORK_DIR/sysroot-overlay-$DEB_ARCH"; rm -rf "$overlay"; mkdir -p "$overlay"
  fetch_ports_debs "$overlay" $PKGS
  msg "copying staged libraries into $SYSROOT (sudo)"
  sudo cp -a "$overlay/usr/." "$SYSROOT/usr/"
fi

# ---- repair the libcurl.so linker symlink if dangling -------------------
# The SDK ships libcurl.so -> libcurl.so.4.8.0 but not the target; the
# runtime package supplies an soname'd file (libcurl.so.4.x). Point the
# dev symlink at whatever real shared object landed so lld prefers it over
# the static libcurl.a. (arm64/REST only — armhf does not pull libcurl.)
libdir="$SYSROOT/usr/lib/$CROSS_TRIPLE"
if [ -e "$libdir/libcurl.so" ] && [ ! -e "$(readlink -f "$libdir/libcurl.so")" ]; then
  real="$(ls "$libdir"/libcurl.so.4.* 2>/dev/null | sort -V | tail -1)"
  if [ -n "$real" ]; then
    if [ -w "$libdir" ]; then ln -sf "$(basename "$real")" "$libdir/libcurl.so";
    else sudo ln -sf "$(basename "$real")" "$libdir/libcurl.so"; fi
    msg "repaired libcurl.so -> $(basename "$real")"
  fi
fi

# ---- verify -------------------------------------------------------------
msg "verifying augmented sysroot"
ok=1
headers="usr/include/liburing.h usr/include/systemd/sd-daemon.h usr/include/libnl3/netlink/netlink.h"
libs="liburing.so libsystemd.so libnl-3.so libnl-route-3.so libnl-nf-3.so"
[ "$DEB_ARCH" = armhf ] || libs="$libs libcurl.so"
for h in $headers; do
  [ -e "$SYSROOT/$h" ] && echo "  header  $h" || { warn "missing $h"; ok=0; }
done
for l in $libs; do
  found="$(find "$SYSROOT/usr/lib" -name "$l" 2>/dev/null | head -1)"
  [ -n "$found" ] && echo "  lib     ${found#"$SYSROOT"/}" || { warn "missing $l (linker symlink)"; ok=0; }
done
[ "$ok" = 1 ] || die "sysroot augmentation incomplete"
msg "sysroot augmented; you can now run ./build-mrpd.sh"
