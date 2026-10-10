#!/usr/bin/env python3
"""Differential fuzzer: real ARM firmware (Unicorn) vs C model vs 68000 replacement.

Starts from a captured state, then for each synthetic frame injects random EST requests
(spawns with every script, every request id, random parameters) and random player
positions, and runs cmd 09, 0A, 12, 14 through all three implementations, comparing the
68k-visible shared RAM and the engine state after every command. The real firmware is
the reference; its result becomes the next command's input for all three.

usage: fuzz.py <capture_dir> [--frames N] [--seed S] [--scripts 1,33,45]
"""
import argparse
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "m68k"))
import hle_test as H  # noqa: E402
from armref import ArmRef  # noqa: E402
from capture import read_capture  # noqa: E402
from m68r import M68k  # noqa: E402

POOL, OBJ, NOBJ = 0x90, 0x44, 128


def pick_state(capdir, nth):
    n = 0
    for ev in read_capture(os.path.join(capdir, "capture.bin")):
        if ev.type == 1 and (ev.aux & 0xffff) == 0x12:
            n += 1
            if n >= nth:
                return tuple(bytes(r) for r in ev.regions), ev.value & 0xff
    raise SystemExit("not enough commands in capture")


def make_requests(rng, shared, wram, scripts, nscripts):
    """random requests into shared $1F80, count into header word 0"""
    reqs = []
    live = [i for i in range(NOBJ) if struct.unpack_from("<H", wram, POOL + i * OBJ)[0]]
    budget = NOBJ - len(live) - 24          # never fill the pool (the firmware would hang)
    for _ in range(rng.randint(0, 12)):
        if budget <= 0:
            break
        kind = rng.random()
        w = [0] * 12
        if kind < 0.7:
            w[0] = 0                                  # scripted bullet
            w[1] = rng.randint(0, 0x34)               # type
            w[2] = rng.randint(-20, 470) & 0xffff     # x
            w[3] = rng.randint(-20, 240) & 0xffff     # y
            w[4] = rng.randint(0, 255)                # angle
            w[5] = rng.choice([0, 0x80, 0x100, 0x180, 0x200, 0x300, rng.randint(0, 0x600)])
            w[6] = rng.choice([0, 0x40, rng.randint(0, 0x200)])
            w[7] = rng.randint(0, 6)                  # anim period
            w[8] = rng.choice([0, 1, 2, 3])           # sub type
            w[9] = rng.randint(0, 20)
            w[10] = rng.choice([0, 1, 2, rng.randint(0, 40)])
            w[11] = rng.choice(scripts) if rng.random() < 0.8 else rng.randint(0, nscripts - 1)
        else:
            w[0] = rng.randint(1, 14)
            w[1] = rng.choice(live) if (w[0] in (1, 2, 3, 13) and live) else rng.randint(4, 12)
            if w[0] in (1, 2, 3, 13) and not live:
                continue
            w[2] = rng.randint(0, 448)
            w[3] = rng.randint(0, 224)
            w[4] = rng.randint(0, 40)                 # item id
            w[5] = rng.choice([1, 2])
            w[6] = rng.randint(0, 6)
        budget -= w[6] if w[0] == 8 else 1
        if budget < 0:
            break
        reqs.append(w)
    sh = bytearray(shared)
    for i, w in enumerate(reqs):
        for k, v in enumerate(w):
            struct.pack_into("<H", sh, 0x1F80 + 24 * i + 2 * k, v & 0xffff)
    struct.pack_into("<H", sh, 0x1F00, len(reqs))
    return bytes(sh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture_dir")
    ap.add_argument("--frames", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--scripts", default="1,33,45")
    ap.add_argument("--start", type=int, default=2000, help="use the state before the Nth captured cmd 12")
    a = ap.parse_args()

    H.load_syms(os.path.join(ROOT, "hle", "build"))
    internal, external, imgs = H.rom_images(os.path.join(ROOT, "work", "arm"))
    arm = ArmRef(internal, external)
    model = H.Model(internal, external)
    cpu = M68k(rom_lo=0x000000, rom_hi=0x4fffff)
    cpu.load(H.SYMS["HLE_BASE"], open(os.path.join(ROOT, "hle", "build", "ddp2_v102_world.bin"), "rb").read())
    for addr, data in imgs.items():
        cpu.load(addr, data)
    cpu.load(H.SYMS["SEND_EXIT"], bytes([0x4e, 0x75]))
    shw, hlev, size = H.SYMS["SHWIN"], H.SYMS["HLEV"], H.SYMS["SHWIN_SIZE"]
    nscripts = struct.unpack_from("<H", external, struct.unpack_from("<I", external, 0x84)[0] - 0x08000000)[0]

    rng = random.Random(a.seed)
    scripts = [int(x) for x in a.scripts.split(",")]
    (shared, wram, iram), seq = pick_state(a.capture_dir, a.start)
    arm.load_state(shared, wram, iram)
    arm.boot_main_loop()
    bad = 0
    ncmd = 0

    def run(cmd, shared_in):
        nonlocal seq, bad, ncmd
        st_sh, st_w, st_i = (bytes(x) for x in arm.state())
        shared_in = bytes(shared_in)
        # reference: the real firmware
        arm.load_state(shared_in, st_w, st_i)
        reply, _, _ = arm.command(cmd, seq)
        r_sh, r_w, r_i = (bytes(x) for x in arm.state())
        # C model
        m_reply, fault, m_sh, m_w = model.run(shared_in, st_w, st_i, cmd, seq)
        # 68000
        win = bytearray(H.hswap(shared_in[:size]))
        win[0x10:0x12] = b"\0\0"
        cpu.load(shw, bytes(win))
        cpu.load(hlev, H.arm_to_hlev(st_w))
        cpu.load(H.SYMS["SEQVAR"], bytes([seq]))
        cpu.set_reg(2, cmd)
        cpu.call(H.SYMS["hle_send"], max_cycles=20_000_000)
        c_sh = H.hswap(cpu.dump(shw, size))
        sys_, pool, glob, rngs = H.hlev_to_armview(cpu.dump(hlev, H.HLEV_SIZE))
        probs = []
        if m_sh[:size] != r_sh[:size] or m_w[:0x3200] != r_w[:0x3200] or m_reply != reply:
            probs.append("model differs from firmware")
        rs = bytearray(r_sh[:size])
        rs[0x10:0x12] = b"\0\0"
        if c_sh != bytes(rs):
            d = next(i for i in range(size) if c_sh[i] != rs[i])
            probs.append("68k shared +%04x %02x vs %02x" % (d, c_sh[d], rs[d]))
        if bytes(pool) != r_w[POOL:POOL + NOBJ * OBJ]:
            d = next(i for i in range(NOBJ * OBJ) if pool[i] != r_w[POOL + i])
            probs.append("68k obj %d byte %#x %02x vs %02x" % (d // OBJ, d % OBJ, pool[d], r_w[POOL + d]))
        if bytes(sys_[0:0x80]) != r_w[0:0x80]:
            probs.append("68k SYS")
        if probs:
            bad += 1
            if bad <= 15:
                print("frame %d cmd %02x: %s" % (f, cmd, "; ".join(probs)))
        ncmd += 1
        seq = (seq + 1) & 0x7f
        return r_sh

    sh = shared
    for f in range(a.frames):
        sh = bytearray(arm.state()[0])
        for k in range(4):   # cmd 09: player 1/2 positions, cmd 0A: item scroll speeds etc.
            struct.pack_into("<H", sh, 0x20 + 2 * k, rng.randint(0, 0x1c0) if k % 2 == 0 else rng.randint(0, 0xe0))
        sh = run(0x09, sh)
        sh = bytearray(sh)
        for k in range(4):
            struct.pack_into("<H", sh, 0x20 + 2 * k, rng.choice([0, 1, 2, 0xffff, 0xfffc, 0xfff0, rng.randint(0, 4)]))
        sh = run(0x0A, sh)
        sh = make_requests(rng, sh, arm.state()[1], scripts, nscripts)
        sh = run(0x13 if rng.random() < 0.1 else 0x12, sh)
        sh = run(0x14, sh)
    print("fuzz: %d commands, %d mismatches" % (ncmd, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
