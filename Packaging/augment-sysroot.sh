#!/usr/bin/env bash
# Augment the Swift cross SDK sysroot with the arm64 system libraries that
# mrpd's dependencies require but the stock SDK does not ship:
#
#   liburing   -> IORingSwift (CIORingShims)
#   libsystemd -> swift-systemd (sd_notify, Type=notify units)
#   libnl-3    -> NetLinkSwift (nl-3, nl-route-3, nl-nf-3)
#   libcurl    -> FoundationNetworking (dragged in by the RestAPI trait under
#                 static linking). The SDK ships only the static libcurl.a,
#                 whose optional backends (rtmp/gssapi/ssh) have unresolved
#                 symbols; the bundled libcurl.so symlink is dangling. Dropping
#                 the real arm64 libcurl.so.4 lets lld link the shared lib
#                 instead (its own deps resolve at runtime, not link time).
#
# Genuine arm64 binaries are downloaded from ports.ubuntu.com and extracted
# into the SDK sysroot. Nothing is taken from the host (amd64) sysroot.
#
# Idempotent: re-running just re-extracts. Override the package set with
# SYSROOT_PKGS, the mirror with PORTS_MIRROR, the suite with UBUNTU_SUITE.
set -euo pipefail
. "$(dirname "$0")/common.sh"

PKGS="${SYSROOT_PKGS:-liburing2 liburing-dev libsystemd0 libsystemd-dev \
  libnl-3-200 libnl-3-dev libnl-route-3-200 libnl-route-3-dev \
  libnl-nf-3-200 libnl-nf-3-dev libnl-genl-3-200 libnl-genl-3-dev \
  libcurl4t64}"

# ---- locate the sysroot -------------------------------------------------
SDK_BUNDLE="$HOME/.swiftpm/swift-sdks/${SWIFT_SDK}.artifactbundle"
SYSROOT="$(find "$SDK_BUNDLE" -maxdepth 4 -type d -name '*.sdk' 2>/dev/null | head -1)"
[ -n "$SYSROOT" ] || die "could not locate sysroot under $SDK_BUNDLE"
msg "augmenting sysroot: $SYSROOT"

# ---- download + extract the arm64 packages into the sysroot -------------
fetch_arm64_debs "$SYSROOT" $PKGS

# ---- repair the libcurl.so linker symlink if dangling -------------------
# The SDK ships libcurl.so -> libcurl.so.4.8.0 but not the target; the
# runtime package supplies an soname'd file (libcurl.so.4.x). Point the
# dev symlink at whatever real shared object landed so lld prefers it over
# the static libcurl.a.
libdir="$SYSROOT/usr/lib/aarch64-linux-gnu"
if [ -e "$libdir/libcurl.so" ] && [ ! -e "$(readlink -f "$libdir/libcurl.so")" ]; then
  real="$(ls "$libdir"/libcurl.so.4.* 2>/dev/null | sort -V | tail -1)"
  if [ -n "$real" ]; then
    ln -sf "$(basename "$real")" "$libdir/libcurl.so"
    msg "repaired libcurl.so -> $(basename "$real")"
  fi
fi

# ---- verify -------------------------------------------------------------
msg "verifying augmented sysroot"
ok=1
for h in usr/include/liburing.h usr/include/systemd/sd-daemon.h; do
  [ -e "$SYSROOT/$h" ] && echo "  header  $h" || { warn "missing $h"; ok=0; }
done
for l in liburing.so libsystemd.so libcurl.so; do
  found="$(find "$SYSROOT/usr/lib" -name "$l" 2>/dev/null | head -1)"
  [ -n "$found" ] && echo "  lib     ${found#"$SYSROOT"/}" || { warn "missing $l (linker symlink)"; ok=0; }
done
[ "$ok" = 1 ] || die "sysroot augmentation incomplete"
msg "sysroot augmented; you can now run ./build-mrpd.sh"
