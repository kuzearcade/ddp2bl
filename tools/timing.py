#!/usr/bin/env python3
"""Timing analysis of a MAME capture (feasibility gate for the 68000 replacement).

Reports:
  * cmd 14 polls answered "not done" ($D00020 != 1) - each one changes 68k-visible state;
  * EST job durations (ARM cycles between busy-flag set and clear, from record type 4);
  * 68k idle time per frame (record type 5): the slack available to absorb extra 68k work;
  * the worst frames, with the EST job size and idle margin side by side.

usage: timing.py <capture_dir>
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capture import read_capture, shared_word68k  # noqa: E402

CYC_PER_FRAME = 337920  # 20 MHz 68000, 10 MHz pixel clock, 640 x 264


def main(d):
    not_done = 0
    polls14 = 0
    job_start = None
    jobs = []                       # (frame, arm cycles)
    idle_by_frame = collections.defaultdict(int)
    work_by_frame = {}
    last_cmd = None
    frame = 0
    for ev in read_capture(os.path.join(d, "capture.bin")):
        if ev.type == 1:
            last_cmd = ev.aux & 0xffff
            frame = ev.frame
        elif ev.type == 2 and last_cmd == 0x14 and (ev.value & 0xff) != 0x80:
            polls14 += 1
            if shared_word68k(ev.regions[0], 0x20) != 1:
                not_done += 1
                if not_done <= 20:
                    print("frame %d: cmd 14 answered not-done" % ev.frame)
        elif ev.type == 4:
            if ev.value & 0xffff:
                job_start = ev.cycarm
            elif job_start is not None:
                jobs.append((ev.frame, ev.cycarm - job_start))
                job_start = None
        elif ev.type == 5:
            # value = idle reads, aux = cycles spent idle in that period
            idle_by_frame[ev.frame] += ev.aux
    print("cmd 14 polls: %d, not-done answers: %d" % (polls14, not_done))
    if jobs:
        js = sorted(j[1] for j in jobs)
        print("EST jobs: %d, ARM cycles min %d median %d p99 %d max %d" % (
            len(js), js[0], js[len(js) // 2], js[int(len(js) * 0.99)], js[-1]))
    if idle_by_frame:
        frames = sorted(idle_by_frame)
        idle = sorted(idle_by_frame[f] for f in frames)
        print("68k idle cycles/frame over %d frames: min %d p1 %d median %d (frame = %d cycles)" % (
            len(idle), idle[0], idle[len(idle) // 100], idle[len(idle) // 2], CYC_PER_FRAME))
        zero = [f for f in range(frames[0], frames[-1]) if idle_by_frame.get(f, 0) == 0]
        print("frames with no idle period (lag / slowdown candidates): %d" % len(zero))
        jobmax = collections.defaultdict(int)
        for f, c in jobs:
            jobmax[f] = max(jobmax[f], c)
        worst = sorted(frames, key=lambda f: idle_by_frame[f])[:15]
        print("tightest frames: frame idle job_arm_cycles")
        for f in worst:
            print("   %8d %8d %8d" % (f, idle_by_frame[f], jobmax.get(f, 0)))


if __name__ == "__main__":
    main(sys.argv[1])
