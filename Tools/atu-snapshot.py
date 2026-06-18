#!/usr/bin/env python3
"""
mv88e6xxx ATU (Address Translation Unit) snapshot + decoder.

Take a devlink ATU region snapshot and decode the 12-byte entries, or parse a
previously captured `devlink region read .../atu` hex dump (offline).

Entry layout (drivers/net/dsa/mv88e6xxx/devlink.c, mv88e6xxx_region_atu_snapshot):
six host-order (little-endian) u16s per 12-byte entry:

    fid, atu_op, atu_data, mac01, mac23, mac45

    state   = atu_data & 0x000f
    trunk   = atu_data & 0x8000
    portvec = (atu_data & 0x3ff0) >> 4      (destination port vector / DPV)
    trunkid = (atu_data & 0x00f0) >> 4      (when trunk bit set)
    mac[2i] = u16 >> 8 ; mac[2i+1] = u16 & 0xff

NOTE on FID: read via the *register* GetNext path (RMU off) the FID column is
authoritative. Via the RMU bulk-dump path it is misreported -- disable RMU for a
trustworthy per-FID view.

Examples:
    # live, auto-detect the /atu region:
    ./atu-snapshot.py
    # live, explicit device:
    ./atu-snapshot.py --dev mdio_bus/d0032004.mdio-mii:03
    # decode a pasted dump:
    ./atu-snapshot.py --file dump.txt
    devlink region read .../atu snapshot 0 address 0 length 4096 | ./atu-snapshot.py -
"""

import argparse
import re
import subprocess
import sys
import time

# Entry-state names, by [is_multicast][state]; from global1.h
# MV88E6XXX_G1_ATU_DATA_STATE_*
UC_STATE = {
    0x0: "UC_UNUSED",
    0x1: "UC_AGE_1_OLDEST",
    0x2: "UC_AGE_2",
    0x3: "UC_AGE_3",
    0x4: "UC_AGE_4",
    0x5: "UC_AGE_5",
    0x6: "UC_AGE_6",
    0x7: "UC_AGE_7_NEWEST",
    0x8: "UC_STATIC_POLICY",
    0x9: "UC_STATIC_POLICY_PO",
    0xA: "UC_STATIC_AVB_NRL",
    0xB: "UC_STATIC_AVB_NRL_PO",
    0xC: "UC_STATIC_DA_MGMT",
    0xD: "UC_STATIC_DA_MGMT_PO",
    0xE: "UC_STATIC",
    0xF: "UC_STATIC_PO",
}
MC_STATE = {
    0x0: "MC_UNUSED",
    0x4: "MC_STATIC_POLICY",
    0x5: "MC_STATIC_AVB_NRL",
    0x6: "MC_STATIC_DA_MGMT",
    0x7: "MC_STATIC",
    0xC: "MC_STATIC_POLICY_PO",
    0xD: "MC_STATIC_AVB_NRL_PO",
    0xE: "MC_STATIC_DA_MGMT_PO",
    0xF: "MC_STATIC_PO",
}

ENTRY_LEN = 12


class Entry:
    __slots__ = ("fid", "atu_op", "atu_data", "mac", "state", "trunk",
                 "portvec", "trunkid")

    def __init__(self, raw):
        def u16(off):  # little-endian
            return raw[off] | (raw[off + 1] << 8)

        self.fid = u16(0)
        self.atu_op = u16(2)
        self.atu_data = u16(4)
        mac = []
        for w in (u16(6), u16(8), u16(10)):
            mac += [w >> 8, w & 0xFF]
        self.mac = bytes(mac)

        self.state = self.atu_data & 0x000F
        self.trunk = bool(self.atu_data & 0x8000)
        self.portvec = (self.atu_data & 0x3FF0) >> 4
        self.trunkid = (self.atu_data & 0x00F0) >> 4

    @property
    def is_multicast(self):
        return bool(self.mac[0] & 0x01)

    @property
    def is_broadcast(self):
        return self.mac == b"\xff\xff\xff\xff\xff\xff"

    @property
    def used(self):
        return self.state != 0 or any(self.mac)

    @property
    def macstr(self):
        return ":".join("%02x" % b for b in self.mac)

    @property
    def statestr(self):
        table = MC_STATE if self.is_multicast else UC_STATE
        return table.get(self.state, "0x%x?" % self.state)

    def ports(self):
        return [p for p in range(12) if self.portvec & (1 << p)]

    def dpvstr(self):
        if self.trunk:
            return "trunk#%d" % self.trunkid
        ports = self.ports()
        return ("0x%03x [%s]" % (self.portvec,
                                 ",".join(str(p) for p in ports))
                if ports else "0x000 []")

    def tag(self):
        if self.is_broadcast:
            return "BROADCAST"
        if self.is_multicast:
            if self.state in (0x5, 0xD):
                return "MCAST/AVB-NRL"
            return "MCAST"
        return "UNICAST"


def parse_hex(text):
    """Collect raw bytes from a devlink-region-read style hex dump.

    Each line is '<offset> <byte> <byte> ...'; the offset is a long hex token we
    drop, the rest are 2-hex-digit byte tokens. Also tolerates plain hex.
    """
    out = bytearray()
    for line in text.splitlines():
        toks = line.split()
        if not toks:
            continue
        # drop a leading offset token (>= 6 hex digits)
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
        if e.used:
            entries.append(e)
    return entries


def find_atu_dev():
    try:
        out = subprocess.check_output(["devlink", "region", "show"],
                                      text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.exit("devlink region show failed: %s" % exc)
    for line in out.splitlines():
        m = re.match(r"(\S+)/atu\b", line.strip())
        if m:
            return m.group(1)
    sys.exit("no /atu region found in 'devlink region show'")


def live_snapshot(dev, snapshot, length):
    region = "%s/atu" % dev
    subprocess.run(["devlink", "region", "del", region, "snapshot",
                    str(snapshot)],
                   stderr=subprocess.DEVNULL, check=False)
    subprocess.run(["devlink", "region", "new", region, "snapshot",
                    str(snapshot)], check=True)
    out = subprocess.check_output(
        ["devlink", "region", "read", region, "snapshot", str(snapshot),
         "address", "0", "length", str(length)], text=True)
    return out


def get_text(args):
    """Return raw hex text for one snapshot, from --file/stdin or live."""
    if args.file:
        return sys.stdin.read() if args.file == "-" else open(args.file).read()
    if not sys.stdin.isatty() and args.dev is None and not args.watch:
        return sys.stdin.read()
    dev = args.dev or find_atu_dev()
    text = live_snapshot(dev, args.snapshot, args.length)
    if args.save:
        with open(args.save, "w") as fh:
            fh.write(text)
    return text


def filtered(entries, args):
    if args.fid:
        entries = [e for e in entries if e.fid in args.fid]
    if args.mac:
        needle = args.mac.lower()
        entries = [e for e in entries if needle in e.macstr]
    return entries


def fmt(e):
    return "%-4d %-17s %-22s %-18s %s" % (e.fid, e.macstr, e.statestr,
                                          e.dpvstr(), e.tag())


def print_table(entries):
    print("%-4s %-17s %-22s %-18s %s" % ("FID", "MAC", "STATE", "DPV", "KIND"))
    print("-" * 78)
    last_fid = None
    bcast = set()
    for e in sorted(entries, key=lambda x: (x.fid, not x.is_broadcast,
                                            x.macstr)):
        if last_fid is not None and e.fid != last_fid:
            print()
        last_fid = e.fid
        if e.is_broadcast:
            bcast.add(e.fid)
        print(fmt(e))
    fids = sorted({e.fid for e in entries})
    missing = [f for f in fids if f not in bcast]
    print()
    print("FIDs present: %s" % ", ".join(map(str, fids)))
    print("FIDs with ff:ff broadcast: %s" %
          (", ".join(map(str, sorted(bcast))) or "(none)"))
    if missing:
        print("FIDs WITHOUT broadcast: %s   <-- ARP/broadcast needs flooding "
              "on these" % ", ".join(map(str, missing)))


def diff_entries(old, new):
    """Return (removed, added, changed) keyed by (fid, mac)."""
    key = lambda e: (e.fid, e.macstr)
    om = {key(e): e for e in old}
    nm = {key(e): e for e in new}
    removed = [om[k] for k in om if k not in nm]
    added = [nm[k] for k in nm if k not in om]
    changed = [(om[k], nm[k]) for k in om
               if k in nm and om[k].atu_data != nm[k].atu_data]
    return removed, added, changed


def print_diff(removed, added, changed, prefix=""):
    for e in sorted(removed, key=lambda x: (x.fid, x.macstr)):
        print("%s- %s" % (prefix, fmt(e)))
    for e in sorted(added, key=lambda x: (x.fid, x.macstr)):
        print("%s+ %s" % (prefix, fmt(e)))
    for o, n in sorted(changed, key=lambda x: (x[0].fid, x[0].macstr)):
        print("%s~ FID %d %s  %s %s -> %s %s" %
              (prefix, o.fid, o.macstr, o.statestr, o.dpvstr(),
               n.statestr, n.dpvstr()))


def main():
    ap = argparse.ArgumentParser(description="mv88e6xxx ATU snapshot/decoder")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--dev", help="devlink dev (e.g. mdio_bus/...:03); "
                                    "default: auto-detect the /atu region")
    src.add_argument("--file", "-f", help="decode a saved hex dump "
                                           "('-' for stdin)")
    ap.add_argument("--snapshot", type=int, default=0,
                    help="snapshot id for the live read (default 0)")
    ap.add_argument("--length", type=int, default=4096,
                    help="bytes to read for the live snapshot (default 4096)")
    ap.add_argument("--fid", type=int, action="append",
                    help="only show this FID (repeatable)")
    ap.add_argument("--mac", help="only show entries whose MAC contains this "
                                  "substring, e.g. 91:e0:f0 or ff:ff")
    ap.add_argument("--save", metavar="FILE",
                    help="also write the raw live snapshot to FILE")
    ap.add_argument("--diff", nargs=2, metavar=("OLD", "NEW"),
                    help="decode two saved dumps and show -removed/+added/"
                         "~changed")
    ap.add_argument("--watch", action="store_true",
                    help="poll the live ATU and print entries as they "
                         "appear/disappear (Ctrl-C to stop)")
    ap.add_argument("--interval", type=float, default=1.0,
                    help="seconds between --watch polls (default 1)")
    args = ap.parse_args()

    # compare two saved dumps
    if args.diff:
        old = filtered(decode(parse_hex(open(args.diff[0]).read())), args)
        new = filtered(decode(parse_hex(open(args.diff[1]).read())), args)
        removed, added, changed = diff_entries(old, new)
        if not (removed or added or changed):
            print("(no differences)")
        else:
            print("--- %s\n+++ %s" % tuple(args.diff))
            print_diff(removed, added, changed)
        return

    # live monitor: print deltas as they happen (great for catching the exact
    # moment an entry like FID-2 ff:ff disappears)
    if args.watch:
        dev = args.dev or find_atu_dev()
        prev = None
        print("watching %s/atu every %gs (Ctrl-C to stop); "
              "'-' removed '+' added '~' changed" % (dev, args.interval))
        try:
            while True:
                cur = filtered(decode(parse_hex(
                    live_snapshot(dev, args.snapshot, args.length))), args)
                if prev is None:
                    print_table(cur)
                    print("--- watching for changes ---")
                else:
                    r, a, c = diff_entries(prev, cur)
                    if r or a or c:
                        print_diff(r, a, c, prefix=time.strftime("%H:%M:%S "))
                prev = cur
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print()
        return

    # single snapshot
    entries = filtered(decode(parse_hex(get_text(args))), args)
    if not entries:
        print("(no ATU entries)")
        return
    print_table(entries)


if __name__ == "__main__":
    main()
