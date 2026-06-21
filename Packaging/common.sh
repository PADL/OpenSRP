# Shared configuration and helpers for building Debian (.deb) packages for the
# AVB/TSN switch stack, cross-compiled on this x86_64 Ubuntu host for DEB_ARCH
# (arm64 or armhf).
#
# Sourced by the build-*.sh scripts; not meant to be run on its own.
#
# Versioning (see resolve_version):
#   PKG_VERSION=1.2.3   ./build-foo.sh   # explicit version, used verbatim
#   PKG_USE_TAG=1        ./build-foo.sh   # version from `git describe --tags`
#   (default)            ./build-foo.sh   # short git commit hash
#
# Everything else (toolchain, paths) can be overridden via the env vars below.

set -euo pipefail

# ---- target / toolchain -------------------------------------------------
# DEB_ARCH is the single source of truth; the cross-triple and the Linux `make
# ARCH=` value (which differs from the Debian arch name) are derived from it.
# Override any of them explicitly if your toolchain differs. Known targets:
# arm64 (aarch64), armhf (32-bit armv7, arm-linux-gnueabihf).
export DEB_ARCH="${DEB_ARCH:-arm64}"
# Per-arch defaults: cross-triple, Linux `make ARCH=`, the Swift toolchain that
# matches the SDK (swiftly id), and the Swift SDK selector. arm64 uses a modern
# artifactbundle (SWIFT_SDK, --swift-sdk). armhf has no swift.org SDK: it uses
# the swift-embedded-linux armv7 destination JSON in /opt (SWIFT_DESTINATION_
# JSON, --destination), built with Swift 6.3.2 against an Ubuntu noble sysroot —
# so its toolchain must be 6.3.2, not the arm64 default of 6.3.0.
_def_dest_json=""
case "$DEB_ARCH" in
  arm64) _def_triple=aarch64-linux-gnu;   _def_karch=arm64; _def_sdk="6.3-RELEASE_ubuntu_noble_aarch64"; _def_tc=6.3.0 ;;
  armhf) _def_triple=arm-linux-gnueabihf; _def_karch=arm;   _def_sdk=""; _def_tc=6.3.2
         # Use the *-static.json destination: its resource-dir/rpaths point at
         # usr/lib/swift_static, where static-stdlib-args.lnk lives. mrpd always
         # builds with --static-swift-stdlib; the plain ubuntu-noble.json
         # (resource-dir usr/lib/swift) makes the driver look for that .lnk under
         # usr/lib/swift/linux, where it does not exist -> fatal "not found".
         # (--static-swift-stdlib is now a deployment choice, not a glibc-skew
         # necessity: the SDK is noble-based, matching the target's glibc 2.39.)
         _def_dest_json="/opt/swift-6.3.2-RELEASE-ubuntu-noble-armv7/ubuntu-noble-static.json" ;;
  *) printf 'ERROR: unsupported DEB_ARCH %s (known: arm64, armhf)\n' "$DEB_ARCH" >&2; exit 1 ;;
esac
export CROSS_TRIPLE="${CROSS_TRIPLE:-$_def_triple}"
export CROSS_COMPILE="${CROSS_COMPILE:-${CROSS_TRIPLE}-}"
export KERNEL_ARCH="${KERNEL_ARCH:-$_def_karch}"   # Linux `make ARCH=` (arm64|arm)
export SWIFT_TOOLCHAIN="${SWIFT_TOOLCHAIN:-$_def_tc}"  # swiftly toolchain matching the SDK
# armhf: default the destination JSON to the /opt SDK if present (overridable).
[ -n "${SWIFT_DESTINATION_JSON:-}" ] || { [ -n "$_def_dest_json" ] && [ -f "$_def_dest_json" ] && export SWIFT_DESTINATION_JSON="$_def_dest_json"; }
# Swift cross SDK (see `swift sdk list`); MUST match DEB_ARCH. swift.org ships no
# 32-bit ARM Linux SDK, so for armhf set SWIFT_SDK to a community/self-built
# armv7 SDK (e.g. swift-embedded-linux/armhf-debian). Regenerate the aarch64 one
# with swift-sdk-generator if needed.
export SWIFT_SDK="${SWIFT_SDK:-$_def_sdk}"

MAINTAINER="${MAINTAINER:-Luke Howard <lukeh@padl.com>}"

# ---- sources ------------------------------------------------------------
# mrpd is built from THIS repository in place; everything else is checked out
# from git (URL + ref overridable via env).
PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFTMRP_DIR="${SWIFTMRP_DIR:-$(cd "$PACKAGING_DIR/.." && pwd)}"

MSTPD_GIT="${MSTPD_GIT:-https://github.com/mstpd/mstpd.git}"
MSTPD_REF="${MSTPD_REF:-}"                               # empty = default branch

LINUXPTP_GIT="${LINUXPTP_GIT:-https://github.com/PADL/linuxptp.git}"
LINUXPTP_REF="${LINUXPTP_REF:-inferno}"

LINUX_GIT="${LINUX_GIT:-https://github.com/PADL/linux.git}"
LINUX_REF="${LINUX_REF:-rpi-6.18.y-xebros-rmu}"

IPROUTE2_GIT="${IPROUTE2_GIT:-https://github.com/PADL/iproute2.git}"
IPROUTE2_REF="${IPROUTE2_REF:-brport-filter-stream-reserved}"

# ---- output locations ---------------------------------------------------
OUT_DIR="${OUT_DIR:-$PACKAGING_DIR/out}"
WORK_DIR="${WORK_DIR:-$PACKAGING_DIR/.work}"
mkdir -p "$OUT_DIR" "$WORK_DIR"

# ---- logging ------------------------------------------------------------
msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# git_checkout <name> <url> [ref]
# Shallow-clones <url> (at <ref> if given, else the default branch) into
# $WORK_DIR/<name>-src, updating in place if already present. Echoes the path.
# All progress goes to stderr so the path can be captured via $(...).
git_checkout() {
  local name="$1" url="$2" ref="${3:-}"
  local dir="$WORK_DIR/$name-src"
  if [ -d "$dir/.git" ]; then
    msg "updating $name (${ref:-default})" >&2
    git -C "$dir" fetch --depth 1 origin "${ref:-HEAD}" >&2
    git -C "$dir" checkout -q --detach FETCH_HEAD >&2
  else
    msg "cloning $name from $url (${ref:-default})" >&2
    rm -rf "$dir"
    git clone --depth 1 ${ref:+--branch "$ref"} "$url" "$dir" >&2
  fi
  printf '%s' "$dir"
}

# ---- fetching genuine target .debs to augment the SDK sysroot -----------
# Supplies $DEB_ARCH system libraries that the cross toolchains lack, without
# touching the host (amd64) sysroot. The apt source MUST match the SDK's glibc
# generation, or libraries built against a newer glibc drag in symbols the SDK's
# libc.so lacks (e.g. a noble lib references __isoc23_strtoul@GLIBC_2.38, which an
# older glibc 2.36 does not export -> lld --no-allow-shlib-undefined rejects the
# link). Both arches now use noble-glibc-based Swift SDKs -- arm64's swift.org
# artifactbundle, and armhf's swift-embedded-linux armv7 SDK built against a noble
# sysroot -- so both augment from Ubuntu noble (armhf is an Ubuntu ports arch too).
# The mirror layout (dists/<suite>/<component>/binary-<arch>/Packages.gz and the
# pool/ Filename paths) is identical for Debian and Ubuntu, so the same fetch
# code drives both. Override any of these explicitly for a different base.
_def_mirror=http://ports.ubuntu.com/ubuntu-ports
_def_pockets="noble noble-updates noble-security"
_def_components="main universe"
PORTS_MIRROR="${PORTS_MIRROR:-$_def_mirror}"
UBUNTU_POCKETS="${UBUNTU_POCKETS:-$_def_pockets}"
UBUNTU_COMPONENTS="${UBUNTU_COMPONENTS:-$_def_components}"

# _ports_index : ensure the merged $DEB_ARCH Packages index exists; echo its
# path. The merged index is keyed by arch AND a hash of the apt source (mirror +
# pockets + components), so switching DEB_ARCH or pointing at a different suite
# (e.g. a separate fetch of a newer linux-libc-dev from trixie) builds its own
# index instead of silently reusing a stale one.
_ports_index() {
  local tag; tag="$(printf '%s|%s|%s' "$PORTS_MIRROR" "$UBUNTU_POCKETS" "$UBUNTU_COMPONENTS" | cksum | cut -d' ' -f1)"
  local idx="$WORK_DIR/Packages.$DEB_ARCH.$tag.merged"
  [ -s "$idx" ] && { printf '%s' "$idx"; return; }
  local cache="$WORK_DIR/ports-cache"; mkdir -p "$cache"
  : > "$idx"
  local p c f
  for p in $UBUNTU_POCKETS; do
    for c in $UBUNTU_COMPONENTS; do
      f="$cache/Packages_${DEB_ARCH}_${p}_${c}.gz"
      if [ ! -s "$f" ]; then
        msg "fetching $DEB_ARCH index $p/$c" >&2
        curl -fsSL "$PORTS_MIRROR/dists/$p/$c/binary-$DEB_ARCH/Packages.gz" -o "$f" \
          || { warn "no index for $p/$c"; rm -f "$f"; continue; }
      fi
      zcat "$f" >> "$idx"; echo >> "$idx"
    done
  done
  [ -s "$idx" ] || die "no $DEB_ARCH package indices fetched (network?)"
  printf '%s' "$idx"
}

# fetch_ports_debs <destdir> <pkg...>
# Resolve the highest-version $DEB_ARCH .deb for each package and extract it
# into <destdir> (preserving its /usr tree).
fetch_ports_debs() {
  local dest="$1"; shift
  local idx; idx="$(_ports_index)"
  local cache="$WORK_DIR/ports-cache"
  local pkg v f bv bf deb
  for pkg in "$@"; do
    bv=""; bf=""
    while IFS=$'\t' read -r v f; do
      if [ -z "$bv" ] || dpkg --compare-versions "$v" gt "$bv"; then bv="$v"; bf="$f"; fi
    done < <(awk -v p="$pkg" '
      BEGIN{RS="";FS="\n"}
      { pk=vr=fl="";
        for(i=1;i<=NF;i++){
          if($i ~ /^Package: /)       pk=substr($i,10);
          else if($i ~ /^Version: /)  vr=substr($i,10);
          else if($i ~ /^Filename: /) fl=substr($i,11);
        }
        if(pk==p && fl!="") print vr"\t"fl
      }' "$idx")
    [ -n "$bf" ] || die "$DEB_ARCH package '$pkg' not found in indices"
    deb="$cache/$(basename "$bf")"
    [ -s "$deb" ] || { msg "downloading $pkg ($(basename "$bf"))" >&2; curl -fsSL "$PORTS_MIRROR/$bf" -o "$deb"; }
    dpkg-deb -x "$deb" "$dest"
  done
}

# resolve_version <srcdir> [base]
# Priority: $PKG_VERSION (verbatim) > git tag (if $PKG_USE_TAG) > base+git<hash>.
# With a base (e.g. "4.4") the default is a snapshot like "4.4+gitc2cd7cc",
# which sorts after the base release. Without one it's a bare hash. Debian
# upstream versions must start with a digit, so a bare hash is prefixed "0+".
resolve_version() {
  local src="$1" base="${2:-}" v hash
  if [ -n "${PKG_VERSION:-}" ]; then
    v="$PKG_VERSION"
  elif [ -n "${PKG_USE_TAG:-}" ]; then
    v="$(git -C "$src" describe --tags --always --dirty 2>/dev/null)" \
      || die "no git tag found in $src"
    v="${v#v}"
  else
    hash="$(git -C "$src" rev-parse --short HEAD 2>/dev/null)" \
      || die "cannot read git short hash in $src"
    if [ -n "$base" ]; then v="${base}+git${hash}"; else v="$hash"; fi
  fi
  case "$v" in [0-9]*) : ;; *) v="0+$v" ;; esac
  # sanitise any characters not allowed in a Debian version
  printf '%s' "$v" | tr -c 'A-Za-z0-9.+~-' '-'
}

# write_systemd_scriptlets <stagedir> <unit...>
# Generates maintainer scripts to enable/disable the given systemd units,
# mirroring what dh_installsystemd would emit.
write_systemd_scriptlets() {
  local stage="$1"; shift
  local units="$*"
  install -d "$stage/DEBIAN"
  cat > "$stage/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  for u in $units; do systemctl enable "\$u" || true; done
fi
EOF
  cat > "$stage/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = remove ] && command -v systemctl >/dev/null 2>&1; then
  for u in $units; do systemctl disable --now "\$u" || true; done
fi
EOF
  cat > "$stage/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
EOF
  chmod 0755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm" "$stage/DEBIAN/postrm"
}

# build_deb <pkg> <version> <stagedir> <depends> <description> [unit...]
# The stagedir must already contain the package's files under their final
# paths (e.g. $stage/usr/sbin/foo). Any DEBIAN/conffiles must be written
# before calling this.
build_deb() {
  local pkg="$1" ver="$2" stage="$3" depends="$4" desc="$5"; shift 5
  install -d "$stage/DEBIAN"
  # --apparent-size counts file sizes (st_size), not allocated blocks; the
  # latter read as ~0 right after writing under ext4 delayed allocation.
  local isize
  isize="$(du -k -s --apparent-size --exclude=DEBIAN "$stage" | cut -f1)"
  # Optional relationship fields (e.g. a variant package that Provides/Conflicts/
  # Replaces the base). Each ends with a newline so it slots in before Section:
  # cleanly, and the line collapses away when all three are unset.
  local relations=""
  [ -n "${DEB_PROVIDES:-}" ]  && relations="${relations}Provides: ${DEB_PROVIDES}"$'\n'
  [ -n "${DEB_CONFLICTS:-}" ] && relations="${relations}Conflicts: ${DEB_CONFLICTS}"$'\n'
  [ -n "${DEB_REPLACES:-}" ]  && relations="${relations}Replaces: ${DEB_REPLACES}"$'\n'
  cat > "$stage/DEBIAN/control" <<EOF
Package: $pkg
Version: $ver
Architecture: $DEB_ARCH
Maintainer: $MAINTAINER
Installed-Size: $isize
Depends: $depends
${relations}Section: net
Priority: optional
Description: $desc
EOF
  if [ "$#" -gt 0 ]; then
    write_systemd_scriptlets "$stage" "$@"
  fi
  local out="$OUT_DIR/${pkg}_${ver}_${DEB_ARCH}.deb"
  dpkg-deb --root-owner-group --build "$stage" "$out" >/dev/null
  msg "built $out"
}
