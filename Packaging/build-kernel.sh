#!/usr/bin/env bash
# Build the Linux kernel as native Ubuntu linux-image / linux-headers .deb
# packages (arm64), using the kernel's own bindeb-pkg target. These install to
# /boot, regenerate the initramfs and run depmod via their maintainer scripts —
# i.e. drop-in replacements for the stock Ubuntu kernel .debs.
#
# Source is checked out from git ($LINUX_GIT @ $LINUX_REF) and configured with
# the Armada switch config kept alongside this script (Packaging/armada.config).
#
# This is the slow one; it is NOT included in build-all by default.
set -euo pipefail
. "$(dirname "$0")/common.sh"

CONFIG="${ARMADA_CONFIG:-$PACKAGING_DIR/armada.config}"
[ -f "$CONFIG" ] || die "armada config not found at $CONFIG (set ARMADA_CONFIG)"

# A full kernel tree is large even shallow-cloned; warn but proceed.
warn "cloning a kernel tree (large); this can take a while and a few GB of disk"
src="$(git_checkout linux "$LINUX_GIT" "$LINUX_REF")"

J="${JOBS:-$(nproc)}"

# Use the Armada switch config verbatim, then reconcile with the source.
msg "applying armada config: $CONFIG"
cp "$CONFIG" "$src/.config"

# KDEB_PKGVERSION sets the .deb version; honour the same overrides as the rest.
KDEB_VER=""
if [ -n "${PKG_VERSION:-}" ]; then
  KDEB_VER="$PKG_VERSION"
elif [ -n "${PKG_USE_TAG:-}" ]; then
  KDEB_VER="$(resolve_version "$src")"
fi

msg "Building Linux kernel .deb ($DEB_ARCH / ARCH=$KERNEL_ARCH) ${KDEB_VER:+version $KDEB_VER}"
# KERNEL_ARCH is the Linux `make ARCH=` value derived from DEB_ARCH in common.sh
# (arm64 -> arm64, armhf -> arm). The $CONFIG (ARMADA_CONFIG) must be a config
# for that arch -- a 64-bit armada.config will not configure an ARCH=arm build.
make -C "$src" ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
# DPKG_FLAGS=-d: skip dpkg-buildpackage's build-dep check. mkdebian pins
# "debhelper-compat (= 12)" but noble ships debhelper 13, which builds
# compat-12 sources fine. Needs host tools: debhelper, libdw-dev.
make -C "$src" ARCH="$KERNEL_ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$J" \
  ${KDEB_VER:+KDEB_PKGVERSION="$KDEB_VER"} \
  DPKG_FLAGS="${KDEB_DPKG_FLAGS:--d}" bindeb-pkg

# bindeb-pkg drops the .deb files in the parent directory of the source tree.
msg "Collecting kernel .deb packages into $OUT_DIR"
parent="$(cd "$src/.." && pwd)"
moved=0
for f in "$parent"/linux-image-*.deb "$parent"/linux-headers-*.deb \
         "$parent"/linux-libc-dev_*.deb; do
  [ -e "$f" ] || continue
  mv -v "$f" "$OUT_DIR"/
  moved=1
done
[ "$moved" = 1 ] || warn "no kernel .deb files found in $parent"
ls -1 "$OUT_DIR"/linux-*.deb 2>/dev/null || true
