#!/usr/bin/env python3
"""Developer tool: derive the 68000 program patch list for a target.

Input: the (unpatched) program ROM, a linear disassembly of it (MAME unidasm), the target
config. Output: targets/<t>/patches.json, a list of
    {"addr": int, "new": hex, "why": str}
that tools/ddp2bl_build.py applies to the program (whose SHA1 it checks first).

Patch kinds
  reloc   : 32-bit operand $00D0xxxx -> SHWIN + xxxx, $00D10000/1 -> latch variable
            (absolute-long operands and immediates; same length, same cycles)
  latch   : the sequence-byte write to the latch (10 bytes) -> "jsr hle_latch_write" + 2 nops
  boot    : the latch read in the start-up check -> "jsr hle_bootcheck" + nop
Only code below code_end is scanned; every hit must be an operand of a decoded
instruction (never the opcode word), which the disassembly provides.
"""
import argparse
import hashlib
import json
import os
import re
import sys

LINE = re.compile(r"^([0-9a-f]+): ((?:[0-9a-f]{4} ?)+)\s+(\S+)\s*(.*)$")


class _Sha1Expect:
    """Expected original code, checked by SHA1 (no original bytes in the repository)."""
    def __init__(self, sha, n):
        self.sha, self.n = sha, n

    def __len__(self):
        return self.n

    def __eq__(self, b):
        return hashlib.sha1(bytes(b)).hexdigest() == self.sha

    def __ne__(self, b):
        return not self == b



def load_symbols(listing):
    syms = {}
    for line in open(listing):
        m = re.match(r"^(\w+)\s+A:([0-9A-F]+)$", line.strip())
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--program", required=True, help="byte-swapped (big endian) program image, base 0x100000")
    ap.add_argument("--dasm", required=True)
    ap.add_argument("--listing", required=True, help="vasm listing of the HLE (for symbol addresses)")
    a = ap.parse_args()

    tdir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "targets", a.target)
    cfg = json.load(open(os.path.join(tdir, "target.json")))
    shwin = int(cfg["reloc_base"], 16)
    hlev = int(cfg["hlev_base"], 16)
    latch_var = hlev + int(cfg["hlev_latch_offset"], 16)
    code_end = int(cfg["code_end"], 16)
    base = 0x100000
    prog = open(a.program, "rb").read()
    syms = load_symbols(a.listing)

    patches = []
    kinds = {}

    def add(addr, new, why):
        o = addr - base
        patches.append({"addr": addr, "new": new.hex(), "why": why})
        kinds[why.split(":")[0]] = kinds.get(why.split(":")[0], 0) + 1

    latch_sites = []
    for line in open(a.dasm):
        m = LINE.match(line.rstrip())
        if not m:
            continue
        addr = int(m.group(1), 16)
        if addr >= code_end:
            break
        words = m.group(2).split()
        text = m.group(4)
        if not re.search(r"\$d[01][0-9a-f]{4}\b", text):
            continue
        if m.group(3) == "move.b" and re.match(r"\$808c9c\.l, \$d10001\.l", text):
            latch_sites.append(addr)
            continue
        # every 00Dx xxxx long in the extension words (never word 0, the opcode)
        for i in range(1, len(words) - 1):
            hi, lo = int(words[i], 16), int(words[i + 1], 16)
            if hi in (0x00d0, 0x00d1):
                old = (hi << 16) | lo
                if hi == 0x00d0:
                    new = shwin + lo
                    if lo >= int(cfg["reloc_size"], 16):
                        sys.exit("offset %#x beyond window at %06x: %s" % (lo, addr, line))
                elif lo in (0, 1):
                    new = latch_var - 1 + lo   # byte at D10001 -> latch variable
                else:
                    sys.exit("unexpected latch address at %06x: %s" % (addr, line))
                add(addr + 2 * i, new.to_bytes(4, "big"), "reloc:%06x" % addr)

    jsr = lambda target: bytes([0x4e, 0xb9]) + target.to_bytes(4, "big")
    nop = bytes([0x4e, 0x71])

    jmp = lambda target: bytes([0x4e, 0xf9]) + target.to_bytes(4, "big")

    def hook(site, expect, target, why):
        o = site - base
        if prog[o:o + len(expect)] != expect:
            sys.exit("%s site %06x does not match the expected code" % (why, site))
        patches[:] = [p for p in patches if not (site <= p["addr"] < site + len(expect))]
        filler = nop * ((len(expect) - 6) // 2)
        add(site, jmp(target) + filler, "%s:%06x" % (why, site))

    # send(): the command write and the latch post -> jmp hle_send
    s = int(cfg["send_hook"], 16)
    hook(s, _Sha1Expect("b1886ae752a2ca75603cf74549f0fd33f9a1ccc9", 16), syms["hle_send"], "send")
    latch_sites.remove(s + 6)
    patches[:] = [p for p in patches if not p["why"].startswith("latch:%06x" % (s + 6))]
    # start-up check: its latch read -> jmp hle_bootcheck
    hook(int(cfg["boot_hook"], 16), _Sha1Expect("211635ae7b4996386675bc5bba01a8d1de09d0b1", 8), syms["hle_bootcheck"], "boot")

    for s in latch_sites:
        add(s, jsr(syms["hle_latch_write"]) + nop + nop, "latch:%06x" % s)
    # region word: the immediate of the HLE's "move.l #0,SHWIN", filled in by the builder
    # from the ARM internal ROM (no ROM data in the repository)
    for line in open(a.listing):
        m = re.match(r"^00:([0-9A-F]{8}) 23FC00000000\S*\s.*region word", line)
        if m:
            patches.append({"addr": int(m.group(1), 16) + 2, "arm_word": cfg["region_word_offset"], "why": "region"})
            kinds["region"] = 1
            break
    else:
        sys.exit("region word site not found in the listing")
    patches.sort(key=lambda p: p["addr"])
    for x, y in zip(patches, patches[1:]):
        if x["addr"] + len(x.get("new", "00" * 4)) // 2 > y["addr"]:
            sys.exit("overlapping patches at %06x / %06x" % (x["addr"], y["addr"]))
    json.dump({"target": a.target, "patches": patches}, open(os.path.join(tdir, "patches.json"), "w"), indent=0)
    print("patches:", len(patches), kinds)


if __name__ == "__main__":
    main()
