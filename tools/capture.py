#!/usr/bin/env python3
"""Reader for capture.bin / coverage.bin produced by the instrumented MAME (DDP2_CAPTURE).

Library use:
    for ev in read_capture(path):      # ev.type: 1 = 68k latch write (command start)
        ...                            #          2 = ARM latch write (reply / echo)
                                       #          3 = 68k latch read
    ev.regions[0..2] are bytearrays (shared RAM in ARM little-endian layout, ARM RAM,
    ARM IRAM) *after* applying this record's diffs; they are live buffers - copy if kept.
    ev.diffs is the list of (region, offset, bytes) carried by the record.

CLI:
    capture.py summary <dir>      per-command statistics, latency, footprint
"""
import collections
import os
import struct
import sys

REC = struct.Struct("<BIIQQII")
REGION_SIZES = (0x10000, 0x10000, 0x400)
REGION_NAMES = ("shared", "armram", "iram")


class Event:
    __slots__ = ("type", "seq", "frame", "cyc68k", "cycarm", "value", "aux", "diffs", "regions")


def read_capture(path):
    regions = [bytearray(n) for n in REGION_SIZES]
    with open(path, "rb") as f:
        data = f.read()
    pos = 0
    n = len(data)
    while pos + REC.size <= n:
        ev = Event()
        ev.type, ev.seq, ev.frame, ev.cyc68k, ev.cycarm, ev.value, ev.aux = REC.unpack_from(data, pos)
        pos += REC.size
        ev.diffs = []
        if ev.type in (1, 2):
            for r in range(3):
                while True:
                    off, ln = struct.unpack_from("<II", data, pos)
                    pos += 8
                    if ln == 0:
                        break
                    chunk = data[pos:pos + ln]
                    pos += ln
                    regions[r][off:off + ln] = chunk
                    ev.diffs.append((r, off, chunk))
        ev.regions = regions
        yield ev


def shared_word68k(shared, addr68k):
    """16-bit value as the 68k sees it at 0xd00000 + addr68k (shared is ARM LE dwords)."""
    # MAME maps 68k word n of 0xd00000 to ARM halfword n (little-endian host, BYTE_XOR_LE = identity)
    off = addr68k & 0xfffe
    return shared[off] | (shared[off + 1] << 8)


def read_coverage(path):
    out = {}
    with open(path, "rb") as f:
        data = f.read()
    pos = 0
    while pos < len(data):
        cmd, nbytes, calls, insns = struct.unpack_from("<IIII", data, pos)
        pos += 16
        exe = data[pos:pos + nbytes]; pos += nbytes
        thumb = data[pos:pos + nbytes]; pos += nbytes
        reads = []
        for _ in range(3):
            (ln,) = struct.unpack_from("<I", data, pos); pos += 4
            reads.append(data[pos:pos + ln]); pos += ln
        out[cmd] = dict(exec=exe, thumb=thumb, reads=reads, calls=calls, insns=insns)
    return out


def bitmap_ranges(bm, base=0, unit=1):
    """Collapse a bitmap into (start, end_exclusive) ranges, scaled by unit."""
    ranges, start = [], None
    nbits = len(bm) * 8
    for i in range(nbits + 1):
        bit = i < nbits and (bm[i >> 3] >> (i & 7)) & 1
        if bit and start is None:
            start = i
        elif not bit and start is not None:
            ranges.append((base + start * unit, base + i * unit))
            start = None
    return ranges


def summary(d):
    cmds = collections.Counter()
    lat_arm = collections.defaultdict(list)
    lat_68k = collections.defaultdict(list)
    polls = collections.defaultdict(list)
    pending = None
    for ev in read_capture(os.path.join(d, "capture.bin")):
        if ev.type == 1:
            cmd = ev.aux & 0xffff
            cmds[cmd] += 1
            pending = [cmd, ev.cycarm, ev.cyc68k, 0, ev.value & 0xff]
        elif ev.type == 2 and pending:
            lat_arm[pending[0]].append(ev.cycarm - pending[1])
        elif ev.type == 3 and pending:
            pending[3] += 1
            if (ev.value & 0xff) == pending[4]:
                lat_68k[pending[0]].append(ev.cyc68k - pending[2])
                polls[pending[0]].append(pending[3])
                pending = None
    print("cmd    calls   ARM cyc (min/avg/max)        68k cyc to echo (min/avg/max)   polls (min/max)")
    for c in sorted(cmds):
        a, b, p = lat_arm[c], lat_68k[c], polls[c]
        fmt = lambda v: "%d/%d/%d" % (min(v), sum(v) // len(v), max(v)) if v else "-"
        print("%04x %8d   %-28s %-31s %s" % (c, cmds[c], fmt(a), fmt(b), "%d/%d" % (min(p), max(p)) if p else "-"))
    cov = os.path.join(d, "coverage.bin")
    if os.path.exists(cov):
        print("\nARM code executed per command (halfword ranges):")
        for cmd, c in sorted(read_coverage(cov).items()):
            r = bitmap_ranges(c["exec"], 0, 2)
            r = [(s if s < 0x4000 else s - 0x4000 + 0x08000000, e if e <= 0x4000 else e - 0x4000 + 0x08000000) for s, e in r]
            print("  cmd %08x calls=%d insns=%d ranges=%d" % (cmd, c["calls"], c["insns"], len(r)))
            for rn, rb in zip(REGION_NAMES, c["reads"]):
                rr = bitmap_ranges(rb)
                if rr:
                    print("     reads %-6s %s" % (rn, " ".join("%x-%x" % x for x in rr[:24]) + (" ..." if len(rr) > 24 else "")))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "summary":
        summary(sys.argv[2])
    else:
        print(__doc__)
