#!/usr/bin/env bash
# Build the switch-stack .deb packages.
#
#   ./build-all.sh                 # mrpd, mstpd, linuxptp, iproute2 (fast)
#   ./build-all.sh kernel          # also build the kernel .deb (slow)
#   ./build-all.sh mrpd linuxptp   # build only the named components
#
# Components: mrpd mstpd linuxptp iproute2 kernel  (or "all" for everything)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/common.sh"

components=("$@")
if [ "${#components[@]}" -eq 0 ]; then
  components=(mrpd mstpd linuxptp iproute2)
elif [ "${components[0]}" = all ]; then
  components=(mrpd mstpd linuxptp iproute2 kernel)
elif [ "${components[0]}" = kernel ] && [ "${#components[@]}" -eq 1 ]; then
  # "kernel" alone means the default set plus the kernel
  components=(mrpd mstpd linuxptp iproute2 kernel)
fi

for c in "${components[@]}"; do
  script="$here/build-$c.sh"
  [ -x "$script" ] || die "unknown component '$c' (no $script)"
  msg "=== $c ==="
  "$script"
done

msg "All requested packages built. Output in $OUT_DIR:"
ls -1 "$OUT_DIR"/*.deb 2>/dev/null || true
