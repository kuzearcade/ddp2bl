#!/usr/bin/env python3
"""Verify the C model (oracle/est_model.c) against a MAME capture, command by command.

The model keeps its own ARM work RAM / IRAM across commands; shared RAM is taken from the
capture at each command start (the 68k writes it). After each command:
  * shared RAM must equal the capture at the ARM's reply (latch write),
  * work RAM (below the stacks) must equal the capture at the next command start,
  * the latch reply must match.
On the first mismatch the model is re-synchronised from the capture so later commands are
still checked; mismatches are reported with the command, frame and first differing object.

usage: test_model.py <capture_dir> [--limit N] [--max-report N]
"""
import argparse
import collections
import ctypes
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
from capture import read_capture  # noqa: E402

WRAM_COMPARE = 0x7000
POOL, OBJ = 0x90, 0x44


class Model:
    def __init__(self, arm_dir):
        self.lib = ctypes.CDLL(os.path.join(HERE, "libestmodel.so"))
        internal = open(os.path.join(arm_dir, "internal.bin"), "rb").read()
        external = open(os.path.join(arm_dir, "external_dec.bin"), "rb").read()
        self.lib.model_load_roms(internal, external)
        self.sh = ctypes.create_string_buffer(0x10000)
        self.wr = ctypes.create_string_buffer(0x10000)
        self.ir = ctypes.create_string_buffer(0x400)

    def set_state(self, shared, wram, iram):
        self.lib.model_set_state(bytes(shared), bytes(wram), bytes(iram))

    def state(self):
        self.lib.model_get_state(self.sh, self.wr, self.ir)
        return self.sh.raw, self.wr.raw, self.ir.raw

    def command(self, cmd, seq):
        f = ctypes.c_int()
        r = self.lib.model_command(cmd, seq, ctypes.byref(f))
        return r & 0xff, f.value


def describe(off):
    if POOL <= off < POOL + 127 * OBJ:
        i, f = divmod(off - POOL, OBJ)
        return "obj %d field %d (byte %#x)" % (i, f // 2, f)
    return "wram+%#x" % off


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture_dir")
    ap.add_argument("--arm", default=os.path.join(HERE, "..", "work", "arm"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-report", type=int, default=15)
    a = ap.parse_args()

    m = Model(a.arm)
    st = collections.Counter()
    faults = collections.Counter()
    resync, pending, job_busy, n, cur = True, None, False, 0, None
    reported = 0

    def report(msg):
        nonlocal reported
        reported += 1
        if reported <= a.max_report:
            print(msg)

    for ev in read_capture(os.path.join(a.capture_dir, "capture.bin")):
        if ev.type == 4:
            job_busy = (ev.value & 0xffff) != 0
            continue
        if ev.type == 1:
            cmd, seq = ev.aux & 0xffff, ev.value & 0xff
            shared, wram, iram = ev.regions
            if pending is not None:
                pcmd, pframe, mw = pending
                if job_busy:
                    st["wram_skipped"] += 1
                else:
                    d = None if mw[:WRAM_COMPARE] == bytes(wram[:WRAM_COMPARE]) else next(i for i in range(WRAM_COMPARE) if mw[i] != wram[i])
                    if d is None:
                        st["wram_ok"] += 1
                    else:
                        st["wram_bad"] += 1
                        resync = True
                        report("frame %d cmd %02x: work RAM %s model %02x capture %02x"
                               % (pframe, pcmd, describe(d), mw[d], wram[d]))
                pending = None
            if resync:
                m.set_state(shared, wram, iram)
                resync = False
            else:
                _, mw, mi = m.state()
                m.set_state(shared, mw, mi)
            reply, fault = m.command(cmd, seq)
            if fault:
                faults[(cmd, fault)] += 1
            cur = (cmd, ev.frame, reply)
            n += 1
            if a.limit and n >= a.limit:
                break
        elif ev.type == 2 and cur is not None:
            if (ev.value & 0xff) == 0x80:
                continue
            cmd, frame, reply = cur
            ms, mw, _ = m.state()
            if reply != (ev.value & 0xff):
                st["reply_bad"] += 1
                report("frame %d cmd %02x: reply %02x vs %02x" % (frame, cmd, reply, ev.value & 0xff))
            d = None if ms == bytes(ev.regions[0]) else next(i for i in range(0x10000) if ms[i] != ev.regions[0][i])
            if d is None:
                st["shared_ok"] += 1
            else:
                st["shared_bad"] += 1
                resync = True
                report("frame %d cmd %02x: shared +%04x model %02x capture %02x"
                       % (frame, cmd, d, ms[d], ev.regions[0][d]))
            pending = (cmd, frame, mw)
            cur = None
    print("commands:", n)
    for k, v in sorted(st.items()):
        print("  %-14s %d" % (k, v))
    for (c, f), v in sorted(faults.items()):
        print("  fault %d on cmd %02x: %d" % (f, c, v))
    return 1 if st["shared_bad"] or st["wram_bad"] or st["reply_bad"] else 0


if __name__ == "__main__":
    sys.exit(main())
