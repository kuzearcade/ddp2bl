#!/usr/bin/env python3
"""Check the job's cycle accounting against MAME (log written with DDP2BL_PROBE).

Probe words (HLEV+PROBE): +0 a3 before the job (0), +4 a3 after it (accounted cycles),
+8 debt at the idle hook, +12 idle residue. Each long is written as two words, high first.
measured = cycles between the first word writes of +0 and +4; it differs from the
accounted cost by a constant (the probe stores themselves) unless an interrupt hit the job.
"""
import collections
import sys

events = []
for line in open(sys.argv[1]):
    off, cyc, val = line.split()
    events.append((int(off), int(cyc), int(val, 16)))
diff = collections.Counter()
start = None
i = 0
while i < len(events):
    off, cyc, val = events[i]
    if off == 0:
        start = cyc
    elif off == 4 and start is not None and i + 1 < len(events) and events[i + 1][0] == 6:
        acc = (val << 16) | events[i + 1][2]
        diff[cyc - start - acc] += 1
        start = None
    i += 1
tot = sum(diff.values())
print("jobs: %d" % tot)
for d, n in diff.most_common(8):
    print("  measured - accounted = %6d : %d" % (d, n))
