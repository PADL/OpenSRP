#!/usr/bin/env bash
# Augment the Swift cross SDK sysroot with the arm64 system libraries that
# mrpd's dependencies require but the stock SDK does not ship:
#
#   liburing   -> IORingSwift (CIORingShims)
#   libsystemd -> swift-systemd (sd_notify, Type=notify units)
#   libnl-3    -> NetLinkSwift (nl-3, nl-route-3, nl-nf-3)
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
  libnl-nf-3-200 libnl-nf-3-dev libnl-genl-3-200 libnl-genl-3-dev}"

# ---- locate the sysroot -------------------------------------------------
SDK_BUNDLE="$HOME/.swiftpm/swift-sdks/${SWIFT_SDK}.artifactbundle"
SYSROOT="$(find "$SDK_BUNDLE" -maxdepth 4 -type d -name '*.sdk' 2>/dev/null | head -1)"
[ -n "$SYSROOT" ] || die "could not locate sysroot under $SDK_BUNDLE"
msg "augmenting sysroot: $SYSROOT"

# ---- download + extract the arm64 packages into the sysroot -------------
fetch_arm64_debs "$SYSROOT" $PKGS

# ---- verify -------------------------------------------------------------
msg "verifying augmented sysroot"
ok=1
for h in usr/include/liburing.h usr/include/systemd/sd-daemon.h; do
  [ -e "$SYSROOT/$h" ] && echo "  header  $h" || { warn "missing $h"; ok=0; }
done
for l in liburing.so libsystemd.so; do
  found="$(find "$SYSROOT/usr/lib" -name "$l" 2>/dev/null | head -1)"
  [ -n "$found" ] && echo "  lib     ${found#"$SYSROOT"/}" || { warn "missing $l (linker symlink)"; ok=0; }
done
[ "$ok" = 1 ] || die "sysroot augmentation incomplete"
msg "sysroot augmented; you can now run ./build-mrpd.sh"
