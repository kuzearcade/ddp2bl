#!/usr/bin/env python3
"""Test the 68000 replacement (hle/) against the verified C model, command by command.

For every command in a MAME capture both implementations start from the same state
(the capture's pre-command state, converted to the 68k layout for the 68000 side):
  * the 68000 code runs in the Musashi bench (harness/m68k) at its ROM address,
  * the C model (oracle/libestmodel.so) runs the same command,
and everything the 68k can observe (the relocated shared window) plus the mirrored
engine state (pool, system variables, parameters, RNG) is compared.

Also reports 68000 cycles per command (Musashi timing; MAME is the final reference).

usage: hle_test.py <capture_dir> --build work/build [--limit N] [--carry]
"""
import argparse
import collections
import ctypes
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(HERE, "m68k"))
from capture import read_capture  # noqa: E402
from m68r import M68k, A4, A5  # noqa: E402

# must match hle/hle.s and the generated target.inc
SYMS = {}
SYS_SIZE, POOL_OFF, OBJ, NOBJ = 0x90, 0x90, 0x44, 128
GLOB_OFF, RNG_M1, RNG_S, RNG_K, RNG_J, LATCH_OFF, HLEV_SIZE = 0x2290, 0x22A0, 0x22A4, 0x2380, 0x2384, 0x2388, 0x23A8
ARM_POOL, ARM_GLOB, ARM_RNG = 0x90, 0x2FA4, 0x3020


def set_cmd(cpu, cmd):
    """send(cmd)'s frame as hle_send sees it: a6 = frame pointer (above the stack pointer,
    M68k.call's default 0x81FFF0), command long at 8(a6)."""
    cpu.set_reg(14, 0x81FFF4)
    cpu.load(0x81FFFC, cmd.to_bytes(4, "big"))
    cpu.set_reg(2, cmd)


def load_syms(build):
    import re
    for line in open(os.path.join(build, "ddp2_v102_world.lst")):
        m = re.match(r"^(\w+)\s+A:([0-9A-F]+)$", line.strip())
        if m:
            SYMS[m.group(1)] = int(m.group(2), 16)
    for line in open(os.path.join(build, "target.inc")):
        p = line.split()
        if len(p) >= 3 and p[1] == "equ":
            v = p[2]
            if v.startswith("$"):
                SYMS[p[0]] = int(v[1:], 16)
            elif "+" in v:
                a, b = v.split("+")
                SYMS[p[0]] = SYMS[a] + int(b.replace("$", ""), 16)


def hswap(b):
    """swap the two bytes of every halfword (ARM little endian <-> 68k big endian)"""
    b = bytes(b)
    out = bytearray(len(b))
    out[0::2] = b[1::2]
    out[1::2] = b[0::2]
    return bytes(out)


def ext_to_68k(addr):
    return 0 if addr == 0 else SYMS["EXTROM"] + addr - 0x08000000


def ext_from_68k(addr):
    return 0 if addr == 0 else addr - SYMS["EXTROM"] + 0x08000000


def arm_to_hlev(wram):
    """ARM work RAM -> HLEV image (68k layout)"""
    h = bytearray(HLEV_SIZE)
    h[0:SYS_SIZE] = hswap(wram[0:SYS_SIZE])
    srch = struct.unpack_from("<I", wram, 0x88)[0]
    hlev = SYMS["HLEV"]
    struct.pack_into(">I", h, 0x88, hlev + POOL_OFF + (srch - 0x18000090) if srch else 0)
    struct.pack_into(">H", h, 0x8c, 0)
    pool = hswap(wram[ARM_POOL:ARM_POOL + NOBJ * OBJ])
    h[POOL_OFF:POOL_OFF + NOBJ * OBJ] = pool
    for i in range(NOBJ):
        o = ARM_POOL + i * OBJ
        sp = struct.unpack_from("<I", wram, o + 0x38)[0]
        struct.pack_into(">I", h, POOL_OFF + i * OBJ + 0x38, ext_to_68k(sp) if 0x08000000 <= sp < 0x08020000 or sp == 0 else sp)
    h[GLOB_OFF:GLOB_OFF + 16] = hswap(wram[ARM_GLOB:ARM_GLOB + 16])
    for i in range(55):
        struct.pack_into(">I", h, RNG_S + 4 * i, struct.unpack_from("<I", wram, ARM_RNG + 4 * i)[0])
    struct.pack_into(">I", h, RNG_M1, struct.unpack_from("<I", wram, ARM_RNG - 4)[0])
    struct.pack_into(">i", h, RNG_K, struct.unpack_from("<i", wram, 0x309C + 0x60)[0])
    struct.pack_into(">i", h, RNG_J, struct.unpack_from("<i", wram, 0x309C + 0x64)[0])
    return bytes(h)


def hlev_to_armview(h):
    """HLEV image -> (sys, pool, glob, rng) in ARM byte layout, for comparison"""
    sys_ = bytearray(hswap(h[0:SYS_SIZE]))
    pool = bytearray(hswap(h[POOL_OFF:POOL_OFF + NOBJ * OBJ]))
    for i in range(NOBJ):
        p = struct.unpack_from(">I", h, POOL_OFF + i * OBJ + 0x38)[0]
        struct.pack_into("<I", pool, i * OBJ + 0x38, ext_from_68k(p) if p else 0)
    glob = hswap(h[GLOB_OFF:GLOB_OFF + 16])
    rng = b"".join(struct.pack("<I", struct.unpack_from(">I", h, RNG_S + 4 * i)[0]) for i in range(55))
    return sys_, pool, glob, rng


def rom_images(arm_dir):
    internal = open(os.path.join(arm_dir, "internal.bin"), "rb").read()
    external = open(os.path.join(arm_dir, "external_dec.bin"), "rb").read()
    imgs = {
        SYMS["SINTAB"]: hswap(internal[0x2890:0x2C90]),
        SYMS["AIMTAB"]: internal[0x2C90:0x4000],
        SYMS["EXTROM"]: hswap(external[0:0x13000]),
    }
    from mulcost import mulcost_table
    imgs[SYMS["MULCOST"]] = mulcost_table(internal)
    tab = struct.unpack_from("<I", external, 0x80)[0] - 0x08000000
    cnt = struct.unpack_from("<H", external, struct.unpack_from("<I", external, 0x84)[0] - 0x08000000)[0]
    imgs[SYMS["CTRLPTR"]] = b"".join(struct.pack(">I", ext_to_68k(struct.unpack_from("<I", external, tab + 4 * i)[0]))
                                     for i in range(cnt))
    return internal, external, imgs


class Model:
    def __init__(self, internal, external):
        self.lib = ctypes.CDLL(os.path.join(ROOT, "oracle", "libestmodel.so"))
        self.lib.model_load_roms(internal, external)
        self.sh = ctypes.create_string_buffer(0x10000)
        self.wr = ctypes.create_string_buffer(0x10000)
        self.ir = ctypes.create_string_buffer(0x400)

    def run(self, shared, wram, iram, cmd, seq):
        self.lib.model_set_state(bytes(shared), bytes(wram), bytes(iram))
        f = ctypes.c_int()
        r = self.lib.model_command(cmd, seq, ctypes.byref(f))
        self.lib.model_get_state(self.sh, self.wr, self.ir)
        return r & 0xff, f.value, self.sh.raw, self.wr.raw


def first_diff(a, b):
    if a == b:
        return None
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return i
    return min(len(a), len(b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture_dir")
    ap.add_argument("--build", default=os.path.join(ROOT, "hle", "build"))
    ap.add_argument("--arm", default=os.path.join(ROOT, "work", "arm"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--max-report", type=int, default=20)
    a = ap.parse_args()

    load_syms(a.build)
    internal, external, imgs = rom_images(a.arm)
    model = Model(internal, external)
    cpu = M68k(rom_lo=0x000000, rom_hi=0x4fffff)
    cpu.load(SYMS["HLE_BASE"], open(os.path.join(a.build, "ddp2_v102_world.bin"), "rb").read())
    for addr, data in imgs.items():
        cpu.load(addr, data)
    shw, hlev, size = SYMS["SHWIN"], SYMS["HLEV"], SYMS["SHWIN_SIZE"]
    cpu.load(SYMS["SEND_EXIT"], bytes([0x4e, 0x75]))   # the game's epilogue: just return here

    st = collections.Counter()
    cyc = collections.defaultdict(list)
    reported = 0
    n = 0
    for ev in read_capture(os.path.join(a.capture_dir, "capture.bin")):
        if ev.type != 1:
            continue
        cmd, seq = ev.aux & 0xffff, ev.value & 0xff
        shared, wram, iram = (bytes(r) for r in ev.regions)
        if cmd == 1 and seq == 0x80:
            continue   # boot handshake: handled by hle_boot, not by the command path
        reply, fault, mshared, mwram = model.run(shared, wram, iram, cmd, seq)
        # 68000 side
        win = bytearray(hswap(shared[:size]))
        win[0x10:0x12] = b"\0\0"     # the patched game never writes the command word
        cpu.load(shw, bytes(win))
        cpu.load(hlev, arm_to_hlev(wram))
        cpu.load(SYMS["SEQVAR"], bytes([seq]))
        set_cmd(cpu, cmd)
        try:
            if cmd == 0x14:
                # the ARM ran the job in the background before this command (the captured
                # ARM state already has it), so cmd 14 only packs: compare the packer and
                # the reply word. Busy answers and all timing: harness/hle_stream_test.py
                c = cpu.call(SYMS["hle_pack"], max_cycles=5_000_000)
                busy = mshared[0x20] == 0 and mshared[0x21] == 0
                if busy:
                    # captured mid-job (the ARM is still animating): no per-command
                    # comparison possible; hle_stream_test.py checks these exactly
                    st["busy"] += 1
                    n += 1
                    continue
                else:
                    cpu.load(shw + 0x20, b"\x00\x01")
                cpu.load(hlev + LATCH_OFF, bytes([reply]))
            else:
                c = cpu.call(SYMS["hle_send"], max_cycles=5_000_000)
                if cmd in (0x12, 0x13):
                    # the ARM starts the job right away (the model runs it here); ours
                    # runs at cmd 14: run the job body now, without packing
                    cpu.load(hlev + 0x238A, b"\0\0")        # PENDING
                    cpu.set_reg(A4, shw)
                    cpu.set_reg(A5, hlev)
                    cpu.call(SYMS["cmd_12" if cmd == 0x12 else "cmd_13"], max_cycles=5_000_000)
        except RuntimeError as e:
            print("frame %d cmd %02x: 68000 %s" % (ev.frame, cmd, e))
            st["bad"] += 1
            continue
        cyc[cmd].append(c)
        win = hswap(cpu.dump(shw, size))
        h = cpu.dump(hlev, HLEV_SIZE)
        latch = h[LATCH_OFF]
        problems = []
        if latch != reply:
            problems.append("latch %02x vs %02x" % (latch, reply))
        d = first_diff(win, mshared[:size])
        if d is not None:
            problems.append("shared +%04x 68k %02x model %02x" % (d, win[d], mshared[d]))
        sys_, pool, glob, rng = hlev_to_armview(h)
        d = first_diff(bytes(sys_[0:0x80]), mwram[0:0x80])
        if d is not None:
            problems.append("SYS +%02x 68k %02x model %02x" % (d, sys_[d], mwram[d]))
        for k in (0x82, 0x84, 0x86):
            if sys_[k:k + 2] != mwram[k:k + 2]:
                problems.append("SYS +%02x" % k)
        d = first_diff(bytes(pool), mwram[ARM_POOL:ARM_POOL + NOBJ * OBJ])
        if d is not None:
            i, f = divmod(d, OBJ)
            o68 = bytes(pool[i * OBJ:(i + 1) * OBJ])
            omd = mwram[ARM_POOL + i * OBJ:ARM_POOL + (i + 1) * OBJ]
            oin = wram[ARM_POOL + i * OBJ:ARM_POOL + (i + 1) * OBJ]
            fields = [k for k in range(0, OBJ, 2) if o68[k:k + 2] != omd[k:k + 2]]
            problems.append("obj %d (state %d) fields %s" % (i, omd[0], ", ".join(
                "%#x: in %04x 68k %04x model %04x" % (k // 2, struct.unpack_from('<H', oin, k)[0],
                struct.unpack_from('<H', o68, k)[0], struct.unpack_from('<H', omd, k)[0]) for k in fields)))
        if glob != mwram[ARM_GLOB:ARM_GLOB + 16]:
            problems.append("GLOB")
        if rng != mwram[ARM_RNG:ARM_RNG + 220]:
            problems.append("RNG")
        if problems:
            st["bad"] += 1
            reported += 1
            if reported <= a.max_report:
                print("frame %d cmd %02x: %s" % (ev.frame, cmd, "; ".join(problems)))
        else:
            st["ok"] += 1
        n += 1
        if a.limit and n >= a.limit:
            break
    print("commands: %d  ok %d  bad %d  (cmd 14 busy answers: %d)" % (n, st["ok"], st["bad"], st["busy"]))
    print("68000 cycles per command (Musashi) min/avg/max:")
    for c, l in sorted(cyc.items()):
        print("  %02x n=%-7d %d / %d / %d" % (c, len(l), min(l), sum(l) // len(l), max(l)))
    return 1 if st["bad"] else 0


if __name__ == "__main__":
    sys.exit(main())
