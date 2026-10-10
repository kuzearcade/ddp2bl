#!/usr/bin/env python3
"""Stream test of the 68000 replacement against a MAME capture of the protected set.

Unlike hle_test.py (every command from the captured state), this carries the 68000
side's own state forward, exactly as in the converted game:
  * before each command, the bytes the 68k itself wrote to the shared window since the
    previous command are applied (taken from the capture);
  * the command runs through hle_send; after cmd 12/13 the idle-loop job (hle_run_job)
    runs, as hle_idle does in the game;
  * the window is compared with the capture after every reply (the result areas are
    compared after cmd 14, since the job packs them during idle), and the engine state
    is compared whenever the protected set's job has finished.
Also checks hle_send's cycle count: 266 + E*94 (Musashi timing + fixed bench offset).

usage: hle_stream_test.py <capture_dir> [--skip N] [--limit N]
"""
import argparse
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "m68k"))
import hle_test as H  # noqa: E402
from capture import read_capture  # noqa: E402
from m68r import M68k  # noqa: E402

RESULT_AREAS = [(0x05E0, 0x1F40), (0x3000, 0x3300)]


def mask_results(b):
    b = bytearray(b)
    for lo, hi in RESULT_AREAS:
        b[lo:hi] = bytes(hi - lo)
    return bytes(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture_dir")
    ap.add_argument("--skip", type=int, default=50, help="commands to skip (boot)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-report", type=int, default=15)
    a = ap.parse_args()

    H.load_syms(os.path.join(ROOT, "hle", "build"))
    
    internal, external, imgs = H.rom_images(os.path.join(ROOT, "work", "arm"))
    cpu = M68k(rom_lo=0x000000, rom_hi=0x4fffff)
    cpu.load(H.SYMS["HLE_BASE"], open(os.path.join(ROOT, "hle", "build", "ddp2_v102_world.bin"), "rb").read())
    for addr, data in imgs.items():
        cpu.load(addr, data)
    cpu.load(H.SYMS["SEND_EXIT"], bytes([0x4e, 0x75]))
    shw, hlev, size = H.SYMS["SHWIN"], H.SYMS["HLEV"], H.SYMS["SHWIN_SIZE"]

    st = collections.Counter()
    cyc = collections.defaultdict(collections.Counter)
    reported = 0
    n = 0
    started = False
    prev_post = None          # capture shared RAM after the previous reply
    pending_cmd = None
    cmd = None

    def report(msg):
        nonlocal reported
        reported += 1
        if reported <= a.max_report:
            print(msg)

    for ev in read_capture(os.path.join(a.capture_dir, "capture.bin")):
        if ev.type == 1:
            n += 1
            if n <= a.skip:
                continue
            shared, wram, iram = (bytes(r) for r in ev.regions)
            cmd, seq = ev.aux & 0xffff, ev.value & 0xff
            if not started:
                win = bytearray(H.hswap(shared[:size]))
                win[0x10:0x12] = b"\0\0"
                cpu.load(shw, bytes(win))
                cpu.load(hlev, H.arm_to_hlev(wram))
                started = True
            else:
                # bytes the 68k wrote since the previous reply
                for i in range(0, size, 2):
                    if shared[i:i + 2] != prev_post[i:i + 2] and i != 0x10:
                        cpu.load(shw + i, bytes([shared[i + 1], shared[i]]))
                if pending_cmd is not None and cmd == 0x14:
                    # the protected set's job has finished: compare the engine state
                    h = cpu.dump(hlev, H.HLEV_SIZE)
                    sys_, pool, glob, rng = H.hlev_to_armview(h)
                    if bytes(pool) != wram[H.ARM_POOL:H.ARM_POOL + H.NOBJ * H.OBJ] or bytes(sys_[0:0x80]) != wram[0:0x80]:
                        st["engine_bad"] += 1
                        report("frame %d: engine state differs before cmd 14" % ev.frame)
                    else:
                        st["engine_ok"] += 1
                    pending_cmd = None
            cpu.load(H.SYMS["SEQVAR"], bytes([seq]))
            cpu.set_reg(2, cmd)
            c = cpu.call(H.SYMS["hle_send"], max_cycles=50_000_000)
            cyc[cmd][c] += 1
            if cmd in (0x12, 0x13):
                cpu.call(H.SYMS["hle_run_job"], max_cycles=50_000_000)
                pending_cmd = cmd
            if a.limit and n - a.skip >= a.limit:
                break
        elif ev.type == 2 and started and cmd is not None and (ev.value & 0xff) != 0x80:
            post = bytes(ev.regions[0])
            ours = H.hswap(cpu.dump(shw, size))
            ref = bytearray(post[:size])
            ref[0x10:0x12] = b"\0\0"
            ref = bytes(ref)
            if cmd in (0x12, 0x13):
                ok = mask_results(ours) == mask_results(ref)
            else:
                ok = ours == ref
            if ok:
                st["window_ok"] += 1
            else:
                st["window_bad"] += 1
                d = next(i for i in range(size) if ours[i] != ref[i])
                report("frame %d cmd %02x: window +%04x ours %02x ref %02x" % (ev.frame, cmd, d, ours[d], ref[d]))
                # resynchronise the window so later commands are still checked
                win = bytearray(H.hswap(post[:size]))
                win[0x10:0x12] = b"\0\0"
                cpu.load(shw, bytes(win))
            prev_post = post
            cmd = None
    print("commands: %d" % (n - a.skip))
    for k, v in sorted(st.items()):
        print("  %-12s %d" % (k, v))
    print("hle_send cycles (Musashi) by command:")
    for c, cnt in sorted(cyc.items()):
        print("  %02x %s" % (c, ", ".join("%d x%d" % kv for kv in sorted(cnt.items())[:6])))
    return 1 if st["window_bad"] or st["engine_bad"] else 0


if __name__ == "__main__":
    sys.exit(main())
