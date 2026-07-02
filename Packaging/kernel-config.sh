#!/bin/sh -eu
# Switch a kernel tree's .config between personalities.
#
#   kernel-config.sh armada-arm64 [tree]   assemble armada.common + armada.arm64, olddefconfig
#   kernel-config.sh armada-arm   [tree]   assemble armada.common + armada.arm, olddefconfig
#   kernel-config.sh <name>       [tree]   restore verbatim from <tree>/.config.<name>
#   kernel-config.sh save <name>  [tree]   save the current .config as <tree>/.config.<name>
#
# The outgoing .config is always snapshotted to <tree>/.config.prev first, so a
# mistaken switch is recoverable. [tree] defaults to ~/CVSRoot/linux.
#
# Example round trip:
#   kernel-config.sh save rpi          # keep the current (RPi) config
#   kernel-config.sh armada-arm64      # build for the Armada switch
#   kernel-config.sh rpi               # back to the RPi config

PACKAGING_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

cmd=${1:?usage: kernel-config.sh <armada-arm64|armada-arm|save <name>|<name>> [tree]}

if [ "$cmd" = save ]; then
  name=${2:?usage: kernel-config.sh save <name> [tree]}
  src=${3:-$HOME/CVSRoot/linux}
  cp "$src/.config" "$src/.config.$name"
  echo "saved $src/.config -> .config.$name"
  exit 0
fi

src=${2:-$HOME/CVSRoot/linux}
[ -f "$src/Makefile" ] || { echo "error: $src is not a kernel tree" >&2; exit 1; }

# snapshot whatever is being replaced
[ -f "$src/.config" ] && cp "$src/.config" "$src/.config.prev"

case "$cmd" in
armada-arm64|armada-arm)
  arch=${cmd#armada-}
  case "$arch" in
  arm64) cross=aarch64-linux-gnu- ;;
  arm) cross=arm-linux-gnueabihf- ;;
  esac
  echo "assembling armada.common + armada.$arch"
  cat "$PACKAGING_DIR/armada.common" "$PACKAGING_DIR/armada.$arch" > "$src/.config"
  make -C "$src" ARCH="$arch" CROSS_COMPILE="$cross" olddefconfig
  echo "note: build with: make -C $src ARCH=$arch CROSS_COMPILE=$cross"
  ;;
*)
  [ -f "$src/.config.$cmd" ] || {
    echo "error: no saved config $src/.config.$cmd (use: kernel-config.sh save $cmd)" >&2
    exit 1
  }
  cp "$src/.config.$cmd" "$src/.config"
  echo "restored .config.$cmd -> $src/.config"
  ;;
esac
