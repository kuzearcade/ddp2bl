#!/usr/bin/env python3
"""Compare the per-frame state hashes of two harness runs (reference vs converted).

usage: compare_runs.py <ref_run_dir> <test_run_dir> [--from FRAME]
Prints per-section counts of differing frames and the differing frame ranges.
"""
import argparse
import os
import sys

SECTIONS = ("mainram", "vram", "palette", "vregs", "z80ram", "pixels")


def load(d):
    h = {}
    for line in open(os.path.join(d, "hashes.txt")):
        p = line.split()
        h[int(p[0])] = p[1:]
    return h


def ranges(frames):
    out, start, prev = [], None, None
    for f in frames:
        if start is None:
            start = prev = f
        elif f == prev + 1:
            prev = f
        else:
            out.append((start, prev))
            start = prev = f
    if start is not None:
        out.append((start, prev))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref")
    ap.add_argument("test")
    ap.add_argument("--from", dest="start", type=int, default=0)
    a = ap.parse_args()
    r, t = load(a.ref), load(a.test)
    common = sorted(f for f in set(r) & set(t) if f >= a.start)
    print("frames compared: %d (%d..%d); only in ref %d, only in test %d" % (
        len(common), common[0], common[-1], len(set(r) - set(t)), len(set(t) - set(r))))
    bad_any = []
    for i, s in enumerate(SECTIONS):
        bad = [f for f in common if r[f][i] != t[f][i]]
        bad_any += bad
        rr = ranges(bad)
        print("  %-8s differing frames: %-7d %s" % (s, len(bad), " ".join("%d-%d" % x for x in rr[:12]) + (" ..." if len(rr) > 12 else "")))
    return 1 if bad_any else 0


if __name__ == "__main__":
    sys.exit(main())
