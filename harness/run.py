#!/usr/bin/env python3
"""Run one MAME session under the ddp2bl harness and record per-frame state hashes.

Examples
  # generate a bot input log on the protected set (cheats on), hashing every frame
  run.py --machine ddp2 --mode bot --seed 7 --cheats lives_p1,invuln_p1 --frames 200000 --out work/runs/s7_ref
  # replay the same inputs on the converted set
  run.py --machine ddp2bl --mode replay --inputs work/runs/s7_ref/inputs.txt --cheats lives_p1,invuln_p1 \
         --frames 200000 --out work/runs/s7_bl

Outputs in --out: inputs.txt (bot mode), hashes.txt (one line per frame:
frame mainram vram palette vregs z80ram pixels), optional dumps/<frame>.bin for
frames listed with --dump, and MAME's stdout/stderr in mame.log.
"""
import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTIONS = ("mainram", "vram", "palette", "vregs", "z80ram", "pixels")
DEFAULT_RTC = "20011010120000"


def read_exact(f, n):
    buf = b""
    while len(buf) < n:
        chunk = f.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def unrelocate(ram, win_base, win_size, locs=None):
    """Converted set: 32-bit pointers into the relocated shared window -> original $D0xxxx.

    The game keeps pointers to ASIC results in its own RAM; after relocation they point
    into the window. Raw share bytes are host order (68k word n = LE halfword at byte n),
    so a 68k long $0081HHLL at an even offset is the byte sequence 81 00 LL HH.
    locs: the offsets where the reference run ever held such a pointer ($00D0xxxx). Only
    those are converted; a value that merely looks like a window address elsewhere (e.g.
    a BCD score "00819880") is the game's own data and stays as it is."""
    import re
    lo, hi = win_base & 0xffff, (win_base + win_size - 1) & 0xffff
    hi_byte = bytes([win_base >> 16 & 0xff, 0x00])
    out = bytearray(ram)
    if locs is not None:
        cand = (i for i in locs if ram[i:i + 2] == hi_byte)
    else:
        cand = (m.start() for m in re.finditer(re.escape(hi_byte) + b"(?=..)", ram, re.S))
    for i in cand:
        if i & 1:
            continue
        v = ram[i + 2] | (ram[i + 3] << 8)
        if lo <= v <= hi:
            off = v - lo
            out[i:i + 4] = bytes([0xd0, 0x00, off & 0xff, off >> 8])
    return bytes(out)


def window_pointer_locs(ram, win_size, locs):
    """Reference run: collect offsets holding a 68k long $00D0xxxx (xxxx < win_size)."""
    import re
    for m in re.finditer(b"\xd0\x00(?=..)", ram, re.S):
        i = m.start()
        if not i & 1 and (ram[i + 2] | (ram[i + 3] << 8)) < win_size:
            locs.add(i)


def consume(fifo_path, out_dir, dump_frames, result, reloc=None, masks=(), ptrlocs=None, collect=None):
    hashes = open(os.path.join(out_dir, "hashes.txt"), "w")
    logical = open(os.path.join(out_dir, "logical.txt"), "w")
    frames = 0
    with open(fifo_path, "rb") as f:
        while True:
            hdr = read_exact(f, 8)
            if hdr is None:
                break
            if hdr[:4] == b"LOGI":
                vframe = struct.unpack("<I", hdr[4:])[0]
                (idx,) = struct.unpack("<I", read_exact(f, 4))
                secs = []
                for _ in range(2):
                    (n,) = struct.unpack("<I", read_exact(f, 4))
                    secs.append(read_exact(f, n))
                if reloc:
                    secs[0] = unrelocate(secs[0], *reloc, locs=ptrlocs)
                if collect is not None:
                    window_pointer_locs(secs[0], collect[1], collect[0])
                masked = bytearray(secs[0])             # game-logic RAM: bookkeeping masked
                for off, n in masks:
                    masked[off:off + n] = bytes(n)
                logical.write("%d %d %s %s %s\n" % (idx, vframe, hashlib.blake2b(secs[0], digest_size=8).hexdigest(),
                                                   hashlib.blake2b(secs[1], digest_size=8).hexdigest(),
                                                   hashlib.blake2b(bytes(masked), digest_size=8).hexdigest()))
                if "L%d" % idx in dump_frames:
                    os.makedirs(os.path.join(out_dir, "dumps"), exist_ok=True)
                    with open(os.path.join(out_dir, "dumps", "L%08d.bin" % idx), "wb") as d:
                        for s_ in secs:
                            d.write(struct.pack("<I", len(s_)))
                            d.write(s_)
                continue
            assert hdr[:4] == b"FRME", hdr
            frame = struct.unpack("<I", hdr[4:])[0]
            secs = []
            for _ in SECTIONS:
                (n,) = struct.unpack("<I", read_exact(f, 4))
                secs.append(read_exact(f, n))
            if reloc:
                secs[0] = unrelocate(secs[0], *reloc, locs=ptrlocs)
            if collect is not None:
                window_pointer_locs(secs[0], collect[1], collect[0])
            hashes.write("%d %s\n" % (frame, " ".join(hashlib.blake2b(s, digest_size=8).hexdigest() for s in secs)))
            if frame in dump_frames:
                os.makedirs(os.path.join(out_dir, "dumps"), exist_ok=True)
                with open(os.path.join(out_dir, "dumps", "%08d.bin" % frame), "wb") as d:
                    for s in secs:
                        d.write(struct.pack("<I", len(s)))
                        d.write(s)
            frames += 1
    hashes.close()
    logical.close()
    result["frames"] = frames


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--machine", required=True)
    ap.add_argument("--target", default="ddp2_v102_world")
    ap.add_argument("--mode", choices=("bot", "replay"), required=True)
    ap.add_argument("--inputs", help="replay: input log to play back")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--players", type=int, default=1)
    ap.add_argument("--style", default="random", choices=("random", "aim", "max"))
    ap.add_argument("--cheats", default="")
    ap.add_argument("--frames", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--dump", default="", help="comma list of frames whose full state is saved")
    ap.add_argument("--ptrlocs", help="reference run: where to write the offsets of its window pointers "
                    "(default <out>/ptrlocs.txt); converted run: that file (pointer canonicalisation)")
    ap.add_argument("--mame", default=os.path.expanduser("~/DDP2_Repair/mame-ddp2bl/pgm"))
    ap.add_argument("--rompath", default=os.path.join(ROOT, "work", "roms"))
    ap.add_argument("--rtc", default=DEFAULT_RTC)
    ap.add_argument("--capture", action="store_true", help="enable IGS027A protocol capture (protected set)")
    ap.add_argument("--perfect", action="store_true", help="per-instruction CPU interleave")
    ap.add_argument("--speedups", action="store_true", help="keep MAME's ddp2 idle-loop speedups (off by default)")
    ap.add_argument("--extra", default="", help="extra MAME arguments")
    ap.add_argument("--trace", help="first,last frame of a 68000 instruction trace (written to <out>/trace.log)")
    a = ap.parse_args()

    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="ddp2h_")
    fifo = os.path.join(tmp, "state.fifo")
    os.mkfifo(fifo)

    env = dict(os.environ)
    env.update({
        "DDP2H_MODE": a.mode,
        "DDP2H_INPUTS": os.path.abspath(a.inputs) if a.mode == "replay" else os.path.join(out, "inputs.txt"),
        "DDP2H_SEED": str(a.seed),
        "DDP2H_BOT_PLAYERS": str(a.players),
        "DDP2H_BOT_STYLE": a.style,
        "DDP2H_CHEATS": a.cheats,
        "DDP2H_STATE": fifo,
        "DDP2H_FRAMES": str(a.frames),
        "DDP2H_TARGET": os.path.join(ROOT, "targets", a.target, "harness.lua"),
        "DDP2H_RELOC": "1" if a.machine.endswith("bl") else "0",
    })
    if not a.speedups:
        env["DDP2_NOSPEEDUP"] = "1"
    if a.perfect:
        env["DDP2_PERFECT"] = "1"
    if a.capture:
        env["DDP2_CAPTURE"] = out
    if a.machine.endswith("bl"):
        env["DDP2BL_TRAP"] = "1"
    if a.trace:
        env["DDP2H_TRACE"] = a.trace + "," + os.path.join(out, "trace.log")
        a.extra += " -debug -debugger none"

    cmd = [a.mame, a.machine, "-rompath", a.rompath,
           "-autoboot_script", os.path.join(ROOT, "harness", "lua", "harness.lua"),
           "-rtc", a.rtc, "-nothrottle", "-video", "none", "-sound", "none",
           "-skip_gameinfo", "-nvram_directory", os.path.join(tmp, "nvram"),
           "-cfg_directory", os.path.join(tmp, "cfg"), "-noreadconfig",
           "-seconds_to_run", str(a.frames // 50 + 60)] + a.extra.split()

    result = {}
    import json
    tcfg = json.load(open(os.path.join(ROOT, "targets", a.target, "target.json")))
    conv = a.machine.endswith("bl")
    reloc = (int(tcfg["reloc_base"], 16), int(tcfg["reloc_size"], 16)) if conv else None
    masks = [(int(m[0], 16) - 0x800000, m[1]) for m in tcfg.get("bookkeeping_masks", [])]
    ptrlocs, collect = None, None
    if conv:
        if a.ptrlocs and os.path.exists(a.ptrlocs):
            ptrlocs = sorted(int(x) for x in open(a.ptrlocs).read().split())
        else:
            print("warning: no --ptrlocs from the reference run: converting every window-like long")
    else:
        collect = (set(), int(tcfg["reloc_size"], 16))
    t = threading.Thread(target=consume, args=(fifo, out, {(x if x.startswith("L") else int(x)) for x in a.dump.split(",") if x},
                                               result, reloc, masks, ptrlocs, collect))
    t.start()
    with open(os.path.join(out, "mame.log"), "w") as log:
        rc = subprocess.call(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    if t.is_alive():  # MAME exited without ever opening the state pipe: unblock the reader
        try:
            os.close(os.open(fifo, os.O_WRONLY | os.O_NONBLOCK))
        except OSError:
            pass
    t.join()
    if collect is not None:
        with open(a.ptrlocs or os.path.join(out, "ptrlocs.txt"), "w") as f:
            f.write("\n".join(str(i) for i in sorted(collect[0])) + "\n")
    shutil.rmtree(tmp, ignore_errors=True)
    print("%s: rc=%d frames=%d" % (out, rc, result.get("frames", 0)))
    return rc


if __name__ == "__main__":
    sys.exit(main())
