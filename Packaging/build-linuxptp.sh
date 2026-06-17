#!/usr/bin/env bash
# Build the linuxptp .deb (ptp4l/phc2sys/pmc/... from the PADL fork),
# cross-compiled for arm64. Ships ptp4l.service and /etc/gPTP.cfg.
set -euo pipefail
. "$(dirname "$0")/common.sh"

src="$(git_checkout linuxptp "$LINUXPTP_GIT" "$LINUXPTP_REF")"

VER="$(resolve_version "$src" "${LINUXPTP_BASE_VERSION:-4.4}")"
msg "Building linuxptp (arm64) version $VER"

# incdefs.sh probes for optional libraries (nettle/gnutls/gnupg/openssl for PTP
# security, libcap). With a cross CC it still finds the *headers* under the host
# multiarch /usr/include, but the matching arm64 shared libs aren't in the cross
# sysroot, so the link fails. Drop those features for the cross build (none are
# needed for a gPTP switch). Override the list via LINUXPTP_DROP_FEATURES.
INCDEFS="$(CC="${CROSS_COMPILE}gcc" "$src/incdefs.sh")"
for d in ${LINUXPTP_DROP_FEATURES:-HAVE_NETTLE HAVE_GNUTLS HAVE_GNUPG HAVE_OPENSSL HAVE_LIBCAP}; do
  INCDEFS="${INCDEFS//-D$d/}"
done

make -C "$src" clean >/dev/null 2>&1 || true
# incdefs= on the command line overrides the makefile's own detection.
make -C "$src" CROSS_COMPILE="$CROSS_COMPILE" incdefs="$INCDEFS" -j"$(nproc)"

stage="$WORK_DIR/linuxptp"
rm -rf "$stage"; mkdir -p "$stage"
# Pass the same overrides so install doesn't re-detect nettle and relink.
make -C "$src" CROSS_COMPILE="$CROSS_COMPILE" incdefs="$INCDEFS" install \
  DESTDIR="$stage" prefix=/usr sbindir=/usr/sbin mandir=/usr/share/man

install -D -m0644 "$SWIFTMRP_DIR/Configs/ptp4l.service" \
  "$stage/lib/systemd/system/ptp4l.service"
install -D -m0644 "$SWIFTMRP_DIR/Configs/gPTP.cfg" "$stage/etc/gPTP.cfg"

# /etc/gPTP.cfg is configuration — preserve local edits across upgrades.
install -d "$stage/DEBIAN"
echo /etc/gPTP.cfg > "$stage/DEBIAN/conffiles"

# ptp4l.service uses pgrep (procps) and chrt (util-linux).
build_deb linuxptp "$VER" "$stage" \
  "libc6, procps, util-linux" \
  "IEEE 1588 PTP / 802.1AS (gPTP) implementation (ptp4l and tools)" \
  ptp4l.service
