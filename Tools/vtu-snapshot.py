#!/usr/bin/env python3
"""
mv88e6xxx VTU (VLAN Translation Unit) snapshot + decoder.

Take a devlink `vtu` region snapshot and decode per-VID port membership, or
parse a previously captured `devlink region read .../vtu` hex dump (offline).
Answers "is port N a member of VID V, and tagged how?" straight from hardware.

Entry layout (drivers/net/dsa/mv88e6xxx/devlink.c, mv88e6xxx_devlink_vtu_entry):
eight host-order (little-endian) u16s per 16-byte entry:

    fid, sid, op, vid, data0, data1, data2, resvd

    vid    = vid & 0x0fff ; valid = vid & 0x1000 ; page = vid & 0x2000
    fid    = fid & 0x0fff
    member[i] = (data[i // 4] >> ((i % 4) * 4)) & 0x3   (mv88e6185 layout; 6341)
        0 = member, egress unmodified (CPU/DSA ports; chip.c port_vlan_add)
        1 = member, egress untagged
        2 = member, egress tagged
        3 = non-member

The devlink snapshot stores only valid entries. Read via MDIO registers, so on
a switch reachable only over RMU disable it (mv88e6xxx.disable_rmu=1) first.
Port indices are mapped to netdev names via `devlink port show` when live.

Examples:
    ./vtu-snapshot.py                 # live, auto-detect the /vtu region
    ./vtu-snapshot.py 16              # only VID 16
    ./vtu-snapshot.py --dev mdio_bus/d0032004.mdio-mii:03
    devlink region read .../vtu snapshot 0 address 0 length 8192 | ./vtu-snapshot.py -
"""

import argparse
import json
import os
import re
import stat
import subprocess
import sys


def _stdin_is_data():
    """True only if stdin is a pipe or regular file (real piped/redirected
    input), not a tty or /dev/null. A non-interactive run with no input (e.g.
    under a test harness with stdin=/dev/null) must take a live snapshot, not
    read empty stdin and decode zero entries."""
    try:
        mode = os.fstat(sys.stdin.fileno()).st_mode
    except (OSError, ValueError):
        return False
    return stat.S_ISFIFO(mode) or stat.S_ISREG(mode)

ENTRY_LEN = 16
MAX_PORTS = 11
TAGCHAR = {0: "-", 1: "u", 2: "t"}          # egress tag for a member port
RESERVED_VIDS = {0, 0xFFF}                   # 0 and 4095: reserved VTU entries


class Entry:
    __slots__ = ("fid", "sid", "op", "vid_raw", "data")

    def __init__(self, raw):
        def u16(off):  # little-endian
            return raw[off] | (raw[off + 1] << 8)

        self.fid = u16(0) & 0x0FFF
        self.sid = u16(2)
        self.op = u16(4)
        self.vid_raw = u16(6)
        self.data = (u16(8), u16(10), u16(12))

    @property
    def vid(self):
        return self.vid_raw & 0x0FFF

    @property
    def valid(self):
        return bool(self.vid_raw & 0x1000)

    def member(self, port):
        return (self.data[port // 4] >> ((port % 4) * 4)) & 0x3

    def members(self, nports):
        """(port, member_code) for member ports (code != 3), ports < nports."""
        return [(p, self.member(p)) for p in range(nports)
                if self.member(p) != 0x3]

    def memberstr(self, nports, names):
        parts = []
        for p, m in self.members(nports):
            name = names.get(p, "p%d" % p)
            parts.append("%s[%s]" % (name, TAGCHAR.get(m, "?")))
        return " ".join(parts) if parts else "(none)"


def parse_hex(text):
    """Collect raw bytes from a devlink-region-read style hex dump.
    Each line is '<offset> <byte> <byte> ...'; drop a leading long-hex offset."""
    out = bytearray()
    for line in text.splitlines():
        toks = line.split()
        if not toks:
            continue
        if re.fullmatch(r"[0-9a-fA-F]{6,}", toks[0]):
            toks = toks[1:]
        for t in toks:
            if re.fullmatch(r"[0-9a-fA-F]{2}", t):
                out.append(int(t, 16))
    return bytes(out)


def decode(raw):
    entries = []
    for off in range(0, len(raw) - ENTRY_LEN + 1, ENTRY_LEN):
        e = Entry(raw[off:off + ENTRY_LEN])
        if e.valid:
            entries.append(e)
    return entries


def find_vtu_dev():
    try:
        out = subprocess.check_output(["devlink", "region", "show"], text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.exit("devlink region show failed: %s" % exc)
    for line in out.splitlines():
        m = re.match(r"(\S+)/vtu\b", line.strip())
        if m:
            return m.group(1)
    sys.exit("no /vtu region found in 'devlink region show'")


def port_map(dev):
    """{port_index: netdev-or-'cpu'} from `devlink -j port show`, filtered to
    dev; None if unavailable (e.g. offline)."""
    try:
        out = subprocess.check_output(["devlink", "-j", "port", "show"],
                                      text=True, stderr=subprocess.DEVNULL)
        ports = json.loads(out).get("port", {})
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None
    names = {}
    for handle, info in ports.items():
        if not handle.startswith(dev + "/"):
            continue
        idx = info.get("port")
        if idx is None:
            m = re.search(r"/(\d+)$", handle)
            idx = int(m.group(1)) if m else None
        if idx is None:
            continue
        names[idx] = info.get("netdev") or (info.get("flavour") or "p%d" % idx)
    return names or None


def live_snapshot(dev, length):
    # The region caps at one snapshot, so drop any existing ones first (parsed
    # from "region show ... snapshot [N ...]"), let devlink assign the new id,
    # then delete it when done.
    region = "%s/vtu" % dev
    try:
        show = subprocess.check_output(["devlink", "region", "show", region],
                                       text=True, stderr=subprocess.STDOUT)
        m = re.search(r"snapshot\s*\[([\d ]+)\]", show)
        for sid in (m.group(1).split() if m else []):
            subprocess.run(["devlink", "region", "del", region, "snapshot",
                            sid], stderr=subprocess.DEVNULL, check=False)
    except (OSError, subprocess.CalledProcessError):
        pass
    out = subprocess.check_output(["devlink", "region", "new", region],
                                  text=True, stderr=subprocess.STDOUT)
    m = re.search(r"snapshot\s+(\d+)", out)
    snap = m.group(1) if m else "0"
    try:
        return subprocess.check_output(
            ["devlink", "region", "read", region, "snapshot", snap,
             "address", "0", "length", str(length)], text=True)
    finally:
        subprocess.run(["devlink", "region", "del", region, "snapshot", snap],
                       stderr=subprocess.DEVNULL, check=False)


def get_text(args):
    """Return (raw hex text, dev). dev is None for file/stdin (no port map)."""
    if args.file:
        t = sys.stdin.read() if args.file == "-" else open(args.file).read()
        return t, None
    if _stdin_is_data() and args.dev is None:
        return sys.stdin.read(), None
    dev = args.dev or find_vtu_dev()
    return live_snapshot(dev, args.length), dev


def guess_nports(entries):
    """Highest port marked as member (1/2) or explicit non-member (3) in any
    entry, +1. Non-existent ports read back as 0 (unmodified) everywhere, so
    this fences them off when no devlink port map is available."""
    hi = -1
    for e in entries:
        for p in range(MAX_PORTS):
            if e.member(p) != 0:
                hi = max(hi, p)
    return hi + 1 if hi >= 0 else MAX_PORTS


def print_table(entries, nports, names):
    print("%-5s %-4s %s" % ("VID", "FID", "MEMBERS  (u=untagged t=tagged "
                            "-=unmodified/CPU)"))
    print("-" * 70)
    for e in sorted(entries, key=lambda x: x.vid):
        note = "  (reserved)" if e.vid in RESERVED_VIDS else ""
        print("%-5d %-4d %s%s" % (e.vid, e.fid, e.memberstr(nports, names),
                                  note))
    if not entries:
        print("(no valid VTU entries)")


def main():
    ap = argparse.ArgumentParser(description="mv88e6xxx VTU snapshot/decoder")
    ap.add_argument("vid", nargs="?",
                    help="only show this VID ('-' reads a piped dump on stdin)")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--dev", help="devlink dev (e.g. mdio_bus/...:03); "
                                    "default: auto-detect the /vtu region")
    src.add_argument("--file", "-f", help="decode a saved hex dump "
                                           "('-' for stdin)")
    ap.add_argument("--length", type=int, default=8192,
                    help="bytes to read for the live snapshot (default 8192)")
    ap.add_argument("--ports", type=int,
                    help="port count to decode (default: from devlink, else "
                         "inferred)")
    args = ap.parse_args()

    vid = None if args.vid in (None, "-") else int(args.vid)
    text, dev = get_text(args)
    entries = decode(parse_hex(text))
    if vid is not None:
        entries = [e for e in entries if e.vid == vid]

    names = port_map(dev) if dev else None
    nports = args.ports or (max(names) + 1 if names else guess_nports(entries))
    print_table(entries, nports, names or {})


if __name__ == "__main__":
    main()
