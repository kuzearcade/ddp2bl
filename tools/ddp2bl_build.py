#!/usr/bin/env python3
"""Build ddp2bl.zip (ASIC-less DoDonPachi II) from a MAME ddp2.zip.

    python3 ddp2bl_build.py ddp2.zip [-o ddp2bl.zip] [--target ddp2_v102_world] [--images DIR]
                            [--region china|taiwan|japan|korea|hongkong|world]

Standard library only. Every input file is checked against known hashes (the program by
SHA1, before it is patched), and the output hashes are printed.

Output set (4MB, 27C322-sized images):
  ddp2bl_p1.27c322           patched program (2MB) in both halves, so either half of the
                             EPROM works
  ddp2bl_t1/t2.27c322        tile ROM halves
  ddp2bl_a1..a4.27c322       sprite colour ROM quarters
  ddp2bl_b1/b2.27c322        sprite mask ROM halves
  ddp2bl_m1.27c322           samples
"""
import argparse
import hashlib
import json
import os
import struct
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def die(msg):
    sys.exit("error: " + msg)


def crc(b):
    return "%08x" % (zlib.crc32(b) & 0xffffffff)


def sha1(b):
    return hashlib.sha1(b).hexdigest()


def hswap(b):
    out = bytearray(len(b))
    out[0::2] = b[1::2]
    out[1::2] = b[0::2]
    return bytes(out)


def read_source(zpath, cfg):
    files = {}
    with zipfile.ZipFile(zpath) as z:
        by_crc = {"%08x" % i.CRC: i.filename for i in z.infolist()}
        for key, spec in cfg["source_files"].items():
            name = spec["name"] if spec["name"] in z.namelist() else by_crc.get(spec["crc"])
            if name is None:
                die("%s: missing %s (crc %s)" % (zpath, spec["name"], spec["crc"]))
            data = z.read(name)
            if len(data) != spec["size"] or crc(data) != spec["crc"] or ("sha1" in spec and sha1(data) != spec["sha1"]):
                die("%s in %s does not match the expected dump (crc %s, size %d)" % (name, zpath, crc(data), len(data)))
            files[key] = data
    return files


def decrypt_external(enc, internal):
    """pgm_ddp2_decrypt (MAME pgmcrypt.cpp) + the XOR table the internal ROM uploads."""
    out = bytearray(enc)
    for i in range(len(enc) // 2):
        x = enc[2 * i] | (enc[2 * i + 1] << 8)
        if (i & 0x000480) != 0x000080: x ^= 0x0001
        if (i & 0x000042) != 0x000042: x ^= 0x0008
        if (i & 0x008100) == 0x008000: x ^= 0x0010
        if (i & 0x002004) != 0x000004: x ^= 0x0020
        if (i & 0x001800) != 0x000000: x ^= 0x0040
        if (i & 0x000820) == 0x000820: x ^= 0x0080
        out[2 * i] = x & 0xff
        out[2 * i + 1] = x >> 8
    for k in range(len(out) // 4):
        b = internal[0x2780 + (k & 0xff)]
        w = struct.unpack_from("<I", out, 4 * k)[0] ^ ((b << 24) | (b << 8))
        struct.pack_into("<I", out, 4 * k, w)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", help="MAME ddp2.zip")
    ap.add_argument("-o", "--output", default="ddp2bl.zip")
    ap.add_argument("--target", default="ddp2_v102_world")
    ap.add_argument("--images", help="also write the EPROM images to this directory")
    ap.add_argument("--hle", help="68000 replacement binary (default: hle/build/<target>.bin)")
    ap.add_argument("--region", help="region the game reports (the IGS027A's region word); default: "
                    "the one in the source set's ARM ROM (World for ddp2.zip)")
    a = ap.parse_args()

    tdir = os.path.join(ROOT, "targets", a.target)
    cfg = json.load(open(os.path.join(tdir, "target.json")))
    patches = json.load(open(os.path.join(tdir, "patches.json")))["patches"]
    hle_path = a.hle or os.path.join(ROOT, "hle", "build", a.target + ".bin")
    hle = open(hle_path, "rb").read()
    H = lambda k: int(cfg[k], 16)

    if "sha1" not in cfg["source_files"]["program"]:
        die("target.json: the program needs a sha1 (patches carry no original bytes to check)")
    src = read_source(a.source, cfg)
    internal = src["arm_internal"]
    regions = cfg["regions"]
    names = {v: k for k, v in regions.items()}
    if a.region is not None and a.region.lower() not in regions:
        die("unknown region %s (one of: %s)" % (a.region, ", ".join(regions)))
    ext = decrypt_external(src["arm_external"], internal)
    if sha1(ext) != cfg["arm_external_decrypted_sha1"]:
        die("external ARM ROM decryption check failed")

    # ---- program: MAME stores it byte-swapped (ROM_LOAD16_WORD_SWAP); work big endian
    base = 0x100000
    prog = bytearray(hswap(src["program"]))

    def put(addr, data, what):
        o = addr - base
        if addr < H("free_rom_start") or o + len(data) > len(prog):
            die("%s does not fit in free ROM space" % what)
        if any(prog[o:o + len(data)]):
            die("%s would overwrite non-empty ROM at %06x" % (what, addr))
        prog[o:o + len(data)] = data

    if len(hle) > H("hle_max"):
        die("68000 code too large")
    put(H("hle_base"), hle, "68000 code")
    put(H("rom_sintab"), hswap(internal[0x2890:0x2C90]), "sine table")
    put(H("rom_aimtab"), internal[0x2C90:0x4000], "aim table")
    sys.path.insert(0, HERE)
    from mulcost import mulcost_table
    put(H("rom_mulcost"), mulcost_table(internal), "multiply cost table")
    extrom = H("rom_extrom")
    put(extrom, hswap(ext[0:H("extrom_size")]), "external ROM data")
    tab = struct.unpack_from("<I", ext, 0x80)[0] - 0x08000000
    cnt = struct.unpack_from("<H", ext, struct.unpack_from("<I", ext, 0x84)[0] - 0x08000000)[0]
    ptrs = bytearray()
    for i in range(cnt):
        p = struct.unpack_from("<I", ext, tab + 4 * i)[0]
        if p and not (0x08000000 <= p < 0x08000000 + H("extrom_size")) or p & 1:
            die("script pointer %d (%08x) outside the converted data" % (i, p))
        ptrs += struct.pack(">I", p - 0x08000000 + extrom if p else 0)
    put(H("rom_ctrlptr"), bytes(ptrs), "script pointer table")

    for p in patches:
        o = p["addr"] - base
        if "arm_word" in p:
            # region word, from the ARM internal ROM: halfwords swapped (68k long = low:high)
            w = struct.unpack_from("<I", internal, int(p["arm_word"], 16))[0]
            if w >> 16 not in names:
                die("unexpected region word %08x in the ARM ROM" % w)
            if a.region is not None:
                w = (w & 0xffff) | (regions[a.region.lower()] << 16)   # the 68k reads the high half
            region = "%s (%02x)" % (names[w >> 16], w >> 16)
            new = struct.pack(">I", ((w & 0xffff) << 16) | (w >> 16))
            if any(prog[o:o + 4]):
                die("region word site %06x is not the assembled placeholder" % p["addr"])
        else:
            new = bytes.fromhex(p["new"])   # the program's SHA1 was checked by read_source
        if o < 0 or o + len(new) > len(prog):
            die("patch at %06x outside the program" % p["addr"])
        prog[o:o + len(new)] = new

    p1 = hswap(bytes(prog)) * (0x400000 // len(prog))   # the program in both 2MB halves

    # ---- graphics / sound: split to 27C322 sized images
    t, a1, a2, b, m = src["tiles"], src["sprcol0"], src["sprcol1"], src["sprmask"], src["samples"]
    q = 0x400000
    out = [
        ("ddp2bl_p1.27c322", p1),
        ("ddp2bl_t1.27c322", t[:q]), ("ddp2bl_t2.27c322", t[q:]),
        ("ddp2bl_a1.27c322", a1[:q]), ("ddp2bl_a2.27c322", a1[q:]),
        ("ddp2bl_a3.27c322", a2[:q]), ("ddp2bl_a4.27c322", a2[q:]),
        ("ddp2bl_b1.27c322", b[:q]), ("ddp2bl_b2.27c322", b[q:]),
        ("ddp2bl_m1.27c322", m),
    ]
    with zipfile.ZipFile(a.output, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in out:
            z.writestr(zipfile.ZipInfo(name, (1996, 12, 24, 23, 32, 0)), data)
    if a.images:
        os.makedirs(a.images, exist_ok=True)
        for name, data in out:
            open(os.path.join(a.images, name), "wb").write(data)
    print("wrote %s (%d patches, %d bytes of 68000 code), region %s" % (a.output, len(patches), len(hle), region))
    for name, data in out:
        print("  %-20s %7x CRC(%s) SHA1(%s)" % (name, len(data), crc(data), sha1(data)))


if __name__ == "__main__":
    main()
