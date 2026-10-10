#!/usr/bin/env python3
"""Timing margin of the converted game, per logical frame, from a protected-set run.

    margin.py RUN_DIR [--jobs jobs.txt] [--slack slack.txt] [--speedup F]

slack.txt (harness extra script tools/lua/slack.lua): when the game enters its vblank wait
(first read of the frame counter), each vblank, each frame counter write.
jobs.txt (harness/hle_stream_test.py --jobs-out): video frame, cycles of our cmd 14 with the
job, E of the original cmd 14.
The converted game reaches the vblank wait later by the job's cost minus what the original
spent waiting in that send (266 + 94*E). It stays frame-exact only while that "debt" is less
than the time the original game had left before the vblank interrupt ("slack"): the
interrupt (asserted at every frame boundary, k * 337920 cycles) runs a ~14k-cycle handler
before it counts the vblank, and when it lands in our late work instead of the idle loop
the game sees the frame as missed.
"""
import argparse
import os

FRAME = 337920          # 68000 cycles per video frame (10 MHz pixel clock, 640 x 264)


def parse_slack(path):
    vbl, recs, reads = {}, [], []
    for line in open(path):
        e = line.split()
        t = float(e[1])
        if e[0] == "V":
            vbl.setdefault(int(e[2]), t)
        elif e[0] == "R":
            reads.append(t)
        else:
            n = int(e[2])
            rs = [r for r in reads if r < t - 20]          # skip the read of the addq itself
            recs.append((n, rs[0] if rs else None))
            reads = []
    out = []
    for n, entry in recs:
        if entry is None or n not in vbl:
            out.append(None)
            continue
        irq = vbl[n] // FRAME * FRAME
        if irq < entry:
            # the original itself was late (slowdown frame): it waits for the next vblank,
            # so the conversion only has to arrive before the next interrupt
            irq = (entry // FRAME + 1) * FRAME
            out.append(-(irq - entry))           # negative: marks a late original frame
        else:
            out.append(irq - entry)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--jobs")
    ap.add_argument("--slack")
    ap.add_argument("--speedup", type=float, default=1.0, help="assume the job runs F times faster")
    ap.add_argument("--worst", type=int, default=15)
    a = ap.parse_args()
    slack = parse_slack(a.slack or os.path.join(a.run, "slack.txt"))
    vframe = {}
    for line in open(os.path.join(a.run, "logical.txt")):
        p = line.split()
        vframe[int(p[0])] = int(p[1])
    jobs = {}
    for line in open(a.jobs or os.path.join(a.run, "jobs.txt")):
        f, c, e = map(int, line.split()[:3])
        jobs[f] = (c, e)
    rows = []
    for k in range(1, len(slack) + 1):           # record k: the job ran in video frame vframe[k]
        s = slack[k - 1]
        f = vframe.get(k)
        if s is None or f not in jobs:
            continue
        c, e = jobs[f]
        debt = c / a.speedup - (266 + 94 * e) + 74       # +74: measured send() overhead difference
        rows.append((abs(s) - debt, k, f, s, debt, c, e))
    rows.sort()
    print("frames with a job: %d; original late (slack < 0): %d" % (len(rows), sum(1 for r in rows if r[3] < 0)))
    bad = [r for r in rows if r[0] < 0]
    print("frames the conversion would make (later) late: %d" % len(bad))
    for m, k, f, s, debt, c, e in rows[:a.worst]:
        print("  logical %6d  video %6d  slack %7d  debt %7d  margin %7d  (job %d)" % (k, f, s, debt, m, c))
    print("largest debt/slack ratio: %.3f" % max(r[4] / abs(r[3]) for r in rows if r[3]))
    if rows:
        need = max(r[5] / (abs(r[3]) + 266 + 94 * r[6] - 74) for r in rows)
        print("job speedup needed for zero late frames: %.3f (worst frame)" % need)


if __name__ == "__main__":
    main()
