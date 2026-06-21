#!/usr/bin/env bash
# Build the Linux kernel as native Ubuntu linux-image / linux-headers .deb
# packages (for DEB_ARCH), using the kernel's own bindeb-pkg target. These install to
# /boot, regenerate the initramfs and run depmod via their maintainer scripts —
# i.e. drop-in replacements for the stock Ubuntu kernel .debs.
#
# Source is checked out from git ($LINUX_GIT @ $LINUX_REF) and configured from
# the Armada switch config fragments kept alongside this script (armada.common +
# armada.$KERNEL_ARCH; see below).
#
# This is the slow one; it is NOT included in build-all by default.
set -euo pipefail
. "$(dirname "$0")/common.sh"

# The kernel config is assembled from an arch-neutral base (armada.common) plus
# a per-arch fragment (armada.$KERNEL_ARCH: armada.arm64 or armada.arm), merged
# below and reconciled by olddefconfig. This keeps the switch personality
# (DSA/MV88E6XXX/MVNETA/TSN/...) in one shared file across both arches. Set
# ARMADA_CONFIG to a single verbatim full .config to bypass the merge entirely
# (back-compat / debugging). Validate inputs now, before the slow kernel clone.
COMMON="$PACKAGING_DIR/armada.common"
ARCH_FRAG="$PACKAGING_DIR/armada.$KERNEL_ARCH"
if [ -n "${ARMADA_CONFIG:-}" ]; then
  [ -f "$ARMADA_CONFIG" ] || die "ARMADA_CONFIG not found: $ARMADA_CONFIG"
else
  [ -f "$COMMON" ]    || die "kernel config base not found: $COMMON"
  [ -f "$ARCH_FRAG" ] || die "no kernel config fragment for ARCH=$KERNEL_ARCH: $ARCH_FRAG (known: arm64, arm)"
fi

# A full kernel tree is large even shallow-cloned; warn but proceed.
warn "cloning a kernel tree (large); this can take a while and a few GB of disk"
src="$(git_checkout linux "$LINUX_GIT" "$LINUX_REF")"

J="${JOBS:-$(nproc)}"

# Clean on arch switch: bindeb-pkg builds in-tree, so arm64 and arm objects would
# mix if the same checkout is reused across arches. Track the last-built ARCH and
# mrproper when it changes (mrproper also clears .config, which we rewrite below).
arch_stamp="$src/.kbuild_arch"
if [ -f "$arch_stamp" ] && [ "$(cat "$arch_stamp" 2>/dev/null)" != "$KERNEL_ARCH" ]; then
  msg "kernel ARCH changed ($(cat "$arch_stamp") -> $KERNEL_ARCH); make mrproper"
  make -C "$src" mrproper
fi

# Assemble .config, then reconcile with the source via olddefconfig below. The
# per-arch fragment is concatenated LAST so it can override a common default.
if [ -n "${ARMADA_CONFIG:-}" ]; then
  msg "applying verbatim kernel config: $ARMADA_CONFIG"
  cp "$ARMADA_CONFIG" "$src/.config"
else
  msg "merging kernel config: armada.common + armada.$KERNEL_ARCH"
  cat "$COMMON" "$ARCH_FRAG" > "$src/.config"
fi
echo "$KERNEL_ARCH" > "$arch_stamp"

# KDEB_PKGVERSION sets the .deb version; honour the same overrides as the rest.
KDEB_VER=""
if [ -n "${PKG_VERSION:-}" ]; then
  KDEB_VER="$PKG_VERSION"
elif [ -n "${PKG_USE_TAG:-}" ]; then
  KDEB_VER="$(resolve_version "$src")"
fi

msg "Building Linux kernel .deb ($DEB_ARCH / ARCH=$KERNEL_ARCH) ${KDEB_VER:+version $KDEB_VER}"
# KERNEL_ARCH is the Linux `make ARCH=` value derived from DEB_ARCH in common.sh
# (arm64 -> arm64, armhf -> arm). The merged fragments must match that arch --
# armada.common is arch-neutral and armada.$KERNEL_ARCH supplies the arch deltas.
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
