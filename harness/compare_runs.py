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
    # logical frames: state when the game starts each frame, plus sound commands sent
    lr = [l.split() for l in open(os.path.join(a.ref, "logical.txt"))] if os.path.exists(os.path.join(a.ref, "logical.txt")) else []
    lt = [l.split() for l in open(os.path.join(a.test, "logical.txt"))] if os.path.exists(os.path.join(a.test, "logical.txt")) else []
    if lr and lt:
        n = min(len(lr), len(lt))
        ram_bad = [int(lr[i][0]) for i in range(n) if lr[i][2] != lt[i][2]]
        snd_bad = [int(lr[i][0]) for i in range(n) if lr[i][3] != lt[i][3]]
        vf_bad = [int(lr[i][0]) for i in range(n) if lr[i][1] != lt[i][1]]
        ms_bad = [int(lr[i][0]) for i in range(n) if len(lr[i]) > 4 and len(lt[i]) > 4 and lr[i][4] != lt[i][4]]
        print("logical frames compared: %d (ref %d, test %d)" % (n, len(lr), len(lt)))
        for name, b in (("game RAM", ram_bad), ("game-logic RAM", ms_bad), ("sound cmds", snd_bad), ("video frame", vf_bad)):
            rr = ranges(b)
            print("  %-11s differing: %-7d %s" % (name, len(b), " ".join("%d-%d" % x for x in rr[:12]) + (" ..." if len(rr) > 12 else "")))
        # "video frame" above is MAME's frame counter, which ticks 42,000-53,000 cycles into
        # the game's frame; the game itself counts frames from the vblank interrupt (every
        # 337,920 cycles). With slack.txt (tools/lua/slack.lua) in both runs: the vblank
        # period in which each logical frame starts (the game's frame pacing).
        sr, st = os.path.join(a.ref, "slack.txt"), os.path.join(a.test, "slack.txt")
        if os.path.exists(sr) and os.path.exists(st):
            wr = [float(l.split()[1]) for l in open(sr) if l.startswith("W ")]
            wt = [float(l.split()[1]) for l in open(st) if l.startswith("W ")]
            m = min(len(wr), len(wt), n)
            vp_bad = [i + 1 for i in range(m) if int(wr[i] // 337920) != int(wt[i] // 337920)]
            rr = ranges(vp_bad)
            print("  %-11s differing: %-7d %s" % ("vbl period", len(vp_bad), " ".join("%d-%d" % x for x in rr[:12]) + (" ..." if len(rr) > 12 else "")))
            bad_any += vp_bad
        bad_any += ram_bad + snd_bad + vf_bad
    return 1 if bad_any else 0


if __name__ == "__main__":
    sys.exit(main())
