#!/usr/bin/env python3
"""Replay a MAME IGS027A capture through the Unicorn ARM model and compare.

For every command:
  * shared RAM after the FIQ handler must equal the capture at the ARM latch write
    (handlers are the only ARM code that writes shared RAM);
  * ARM work RAM (excluding stacks) must equal the capture at the next command start,
    when the capture shows the background job had finished by then;
  * the latch reply must equal the capture.
The model carries its own ARM RAM forward (so persistent ARM state is exercised); shared
RAM is re-synchronised from the capture at each command start, because the 68k writes it.

usage: validate_armref.py <capture_dir> [--arm work/arm] [--limit N] [--verbose]
"""
import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from armref import ArmRef, load_roms  # noqa: E402
from capture import read_capture  # noqa: E402

WRAM_COMPARE = 0x7000  # stacks live at 0x18007D80-0x18008000


def first_diff(a, b, limit):
    for i in range(limit):
        if a[i] != b[i]:
            return i
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture_dir")
    ap.add_argument("--arm", default=os.path.join(os.path.dirname(__file__), "..", "work", "arm"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    ref = ArmRef(*load_roms(a.arm))
    stats = collections.Counter()
    insn = collections.defaultdict(list)
    booted = False
    resync = True
    cur = None
    pending = None       # (cmd, model wram after command, job_running_flag)
    job_busy = False
    n = 0
    for ev in read_capture(os.path.join(a.capture_dir, "capture.bin")):
        if ev.type == 4:
            job_busy = (ev.value & 0xffff) != 0
            continue
        if ev.type == 1:
            cmd = ev.aux & 0xffff
            seq = ev.value & 0xff
            shared, wram, iram = ev.regions
            if pending is not None:
                pcmd, mwram = pending
                if not job_busy:
                    d = first_diff(mwram, wram, WRAM_COMPARE)
                    if d is None:
                        stats["wram_ok"] += 1
                    else:
                        stats["wram_bad"] += 1
                        resync = True
                        if stats["wram_bad"] <= 10:
                            print("seq %d cmd %02x: work RAM differs at %08x (model %02x capture %02x)"
                                  % (ev.seq, pcmd, 0x18000000 + d, mwram[d], wram[d]))
                else:
                    stats["wram_skipped_job_running"] += 1
            if resync:
                # (re)synchronise the whole model from the capture
                ref.load_state(shared, wram, iram)
                if not booted:
                    ref.boot_main_loop()
                    booted = True
                resync = False
            else:
                ref.load_state(shared, ref.state()[1], ref.state()[2])
            reply, n_fiq, n_bg = ref.command(cmd, seq)
            insn[cmd].append((n_fiq, n_bg))
            cur = (cmd, reply, ref.state())
            pending = None
            n += 1
            if a.limit and n >= a.limit:
                break
            continue
        if ev.type == 2 and cur is not None:
            cmd, reply, (mshared, mwram, miram) = cur
            if reply != (ev.value & 0xff) and (ev.value & 0xff) != 0x80:
                stats["reply_bad"] += 1
                print("cmd %02x: reply model %02x capture %02x" % (cmd, reply, ev.value & 0xff))
            if (ev.value & 0xff) == 0x80:
                continue  # busy marker written at FIQ entry
            d = first_diff(mshared, ev.regions[0], len(mshared))
            if d is None:
                stats["shared_ok"] += 1
            else:
                stats["shared_bad"] += 1
                if stats["shared_bad"] <= 10:
                    print("cmd %02x: shared RAM differs at +%04x (model %02x capture %02x)"
                          % (cmd, d, mshared[d], ev.regions[0][d]))
            pending = (cmd, bytes(mwram))
            cur = None
    print("commands replayed:", n)
    for k, v in sorted(stats.items()):
        print("  %-28s %d" % (k, v))
    print("ARM instructions per command (FIQ handler / background), min-avg-max:")
    for c, l in sorted(insn.items()):
        f = [x[0] for x in l]; b = [x[1] for x in l]
        print("  %02x n=%-7d fiq %d-%d-%d   bg %d-%d-%d" % (c, len(l), min(f), sum(f) // len(f), max(f),
                                                       min(b), sum(b) // len(b), max(b)))
    return 1 if stats["shared_bad"] or stats["wram_bad"] or stats["reply_bad"] else 0


if __name__ == "__main__":
    sys.exit(main())
