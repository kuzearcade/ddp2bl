#!/usr/bin/env python3
"""Extract per-command timing records from a perfect-interleave capture.

Writes <capdir>/timing.csv: seq,frame,cmd,t68_write,tarm_write,tarm_reply,polls,
t68_echo,done14,job_end_arm (for cmd 12: when the EST job finished)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from capture import read_capture, shared_word68k  # noqa: E402


def main(d):
    rows = []
    cur = None
    last12 = None
    for ev in read_capture(os.path.join(d, "capture.bin")):
        if ev.type == 1:
            cur = dict(frame=ev.frame, cmd=ev.aux & 0xffff, t68w=ev.cyc68k, tarmw=ev.cycarm,
                       seq=ev.value & 0xff, polls=0, tarmr=None, t68e=None, done=None, jobend=None,
                       nreq=shared_word68k(ev.regions[0], 0x1f00))
            cur["expect"] = 1 if cur["seq"] == 0x80 else (cur["seq"] + 1) & 0x7f
            rows.append(cur)
            if cur["cmd"] in (0x12, 0x13):
                last12 = cur
        elif ev.type == 2 and cur is not None and (ev.value & 0xff) != 0x80:
            cur["tarmr"] = ev.cycarm
            if cur["cmd"] == 0x14:
                cur["done"] = shared_word68k(ev.regions[0], 0x20)
        elif ev.type == 3 and cur is not None and cur["t68e"] is None:
            cur["polls"] += 1
            if (ev.value & 0xff) == cur["expect"]:
                cur["t68e"] = ev.cyc68k
        elif ev.type == 4 and (ev.value & 0xffff) == 0 and last12 is not None and last12["jobend"] is None:
            last12["jobend"] = ev.cycarm
    with open(os.path.join(d, "timing.csv"), "w") as f:
        f.write("frame,cmd,nreq,t68w,tarmw,tarmr,polls,t68e,done,jobend\n")
        for r in rows:
            f.write(",".join(str(r[k]) for k in ("frame", "cmd", "nreq", "t68w", "tarmw", "tarmr", "polls", "t68e", "done", "jobend")) + "\n")
    print(len(rows), "rows")


if __name__ == "__main__":
    main(sys.argv[1])
