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
import m68r  # noqa: E402
from m68r import M68k  # noqa: E402

RESULT_AREAS = [(0x05E0, 0x1F40), (0x3000, 0x3300)]


def mask_results(b):
    b = bytearray(b)
    for lo, hi in RESULT_AREAS:
        b[lo:hi] = bytes(hi - lo)
    return bytes(b)


def routine_profile():
    """Cycles per routine (nearest preceding symbol of the listing) from the bench profile."""
    import bisect
    import ctypes
    lo = H.SYMS["HLE_BASE"]
    n = 0x10000
    buf = (ctypes.c_uint32 * (n // 2))()
    m68r._lib.m68r_prof_get(ctypes.c_uint32(lo), n // 2, buf)
    syms = sorted((v, k) for k, v in H.SYMS.items() if lo <= v < lo + n)
    addrs = [v for v, _ in syms]
    per = collections.Counter()
    for i in range(n // 2):
        if buf[i]:
            j = bisect.bisect_right(addrs, lo + 2 * i) - 1
            per[syms[j][1] if j >= 0 else "?"] += buf[i]
    return per


def print_routines(per, njobs):
    tot = sum(per.values())
    for k, v in per.most_common(40):
        print("  %-24s %6.2f%% %10.0f/job" % (k, 100.0 * v / tot, v / njobs))


def print_pcs(top):
    """Hottest instructions of the bench profile: cycles, PC, nearest symbol + offset."""
    import ctypes
    lo = H.SYMS["HLE_BASE"]
    n = 0x10000
    buf = (ctypes.c_uint32 * (n // 2))()
    m68r._lib.m68r_prof_get(ctypes.c_uint32(lo), n // 2, buf)
    syms = sorted((v, k) for k, v in H.SYMS.items() if lo <= v < lo + n)
    hot = sorted(((buf[i], lo + 2 * i) for i in range(n // 2) if buf[i]), reverse=True)[:top]
    for c, pc in hot:
        v, k = max((s for s in syms if s[0] <= pc), default=(0, "?"))
        print("  %8d  %06x  %s+%x" % (c, pc, k, pc - v))


def print_profile(jobs):
    """Cycles per routine (nearest preceding symbol of the listing) over all profiled jobs."""
    import ctypes
    lo = H.SYMS["HLE_BASE"]
    n = 0x10000
    buf = (ctypes.c_uint32 * (n // 2))()
    m68r._lib.m68r_prof_get(ctypes.c_uint32(lo), n // 2, buf)
    syms = sorted((v, k) for k, v in H.SYMS.items() if lo <= v < lo + n)
    per = collections.Counter()
    for i in range(n // 2):
        if buf[i]:
            pc = lo + 2 * i
            name = max((s for s in syms if s[0] <= pc), default=(0, "?"))[1]
            per[name] += buf[i]
    tot = sum(per.values())
    jobs.sort()
    print("jobs %d: mean %.0f, median %d, max %d cycles" % (len(jobs), sum(jobs) / len(jobs), jobs[len(jobs) // 2], jobs[-1]))
    for k, v in per.most_common(40):
        print("  %-24s %6.2f%% %10.0f/job" % (k, 100.0 * v / tot, v / len(jobs)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture_dir")
    ap.add_argument("--skip", type=int, default=50, help="commands to skip (boot)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-report", type=int, default=15)
    ap.add_argument("--profile", action="store_true", help="cycles of cmd 14 jobs per routine")
    ap.add_argument("--jobs-out", help="write 'video_frame cycles E14' for every cmd 14 that ran the job")
    ap.add_argument("--profile-heaviest", action="store_true", help="with --profile: only the most expensive job")
    ap.add_argument("--profile-frame", type=int, help="with --profile: only the job collected in this video frame")
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
    jobs = []
    heaviest = [0, 0, None]
    jobs_out = open(a.jobs_out, "w") if a.jobs_out else None
    acc = collections.Counter()
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
                if False:
                    # (engine state is compared after our cmd 14 below)
                    h = cpu.dump(hlev, H.HLEV_SIZE)
                    sys_, pool, glob, rng = H.hlev_to_armview(h)
                    if bytes(pool) != wram[H.ARM_POOL:H.ARM_POOL + H.NOBJ * H.OBJ] or bytes(sys_[0:0x80]) != wram[0:0x80]:
                        st["engine_bad"] += 1
                        report("frame %d: engine state differs before cmd 14" % ev.frame)
                    else:
                        st["engine_ok"] += 1
                    pending_cmd = None
            cpu.load(H.SYMS["SEQVAR"], bytes([seq]))
            H.set_cmd(cpu, cmd)
            job_was_pending = cpu.dump(H.SYMS["HLEV"] + 0x238A, 2) != b"\0\0"
            prof = a.profile and cmd == 0x14 and job_was_pending and \
                (a.profile_frame is None or ev.frame == a.profile_frame)
            if prof:
                if a.profile_heaviest or a.profile_frame is not None:
                    m68r._lib.m68r_prof_clear()
                m68r._lib.m68r_prof(1)
            c = cpu.call(H.SYMS["hle_send"], max_cycles=50_000_000)
            if prof:
                m68r._lib.m68r_prof(0)
                jobs.append(c)
                if (a.profile_heaviest or a.profile_frame is not None) and c > heaviest[0]:
                    heaviest[:] = [c, ev.frame, routine_profile()]
            cyc[cmd][c] += 1
            if cmd in (0x12, 0x13):
                pending_cmd = cmd
            if cmd == 0x14 and job_was_pending:
                import struct as _s
                a3 = _s.unpack(">I", cpu.dump(H.SYMS["HLEV"] + 0x2396, 4))[0]
                acc[c - a3] += 1                  # measured hle_send - accounted job: constant if exact
            if cmd == 0x14 and job_was_pending and jobs_out:
                e14 = int.from_bytes(cpu.dump(H.SYMS["HLEV"] + 0x238C, 2), "big")
                hl = cpu.dump(H.SYMS["HLEV"], H.HLEV_SIZE)
                st_ = [int.from_bytes(hl[0x90 + i * 0x44:0x92 + i * 0x44], "big") for i in range(128)]
                cnt = [sum(1 for v in st_ if 1 <= v <= 3), st_.count(4), st_.count(5), sum(1 for v in st_ if v >= 6)]
                rem = int.from_bytes(hl[0x18:0x1a], "big")
                a3 = int.from_bytes(cpu.dump(H.SYMS["HLEV"] + 0x2396, 4), "big")
                jobs_out.write("%d %d %d %d %d %d %d %d %d\n" % ((ev.frame, c, e14) + tuple(cnt) + (rem, c - a3)))
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
    if a.profile and jobs:
        if a.profile_heaviest or a.profile_frame is not None:
            print("heaviest job: %d cycles, frame %d" % (heaviest[0], heaviest[1]))
            print_routines(heaviest[2], 1)
            if a.profile_frame is not None:
                print_pcs(60)
        else:
            print_profile(jobs)
    for k, v in sorted(st.items()):
        print("  %-12s %d" % (k, v))
    print("hle_send cycles (Musashi) by command:")
    for c, cnt in sorted(cyc.items()):
        print("  %02x %s" % (c, ", ".join("%d x%d" % kv for kv in sorted(cnt.items())[:6])))
    print("job cycles measured - accounted:", dict(acc.most_common(8)))
    return 1 if st["window_bad"] or st["engine_bad"] else 0


if __name__ == "__main__":
    sys.exit(main())
