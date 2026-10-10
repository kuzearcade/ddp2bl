"""MULCOST: extra MULS cycles (2n per product) for each sine table angle.

MC68000 MULS takes 38+2n cycles, n = number of 01/10 bit pairs in the 17-bit value
(source << 1). The job code multiplies by both sine table words of an angle, so the
table holds, per angle, a big-endian long 2n(a) + 2n(b)."""
import struct


def muls_n(v):
    x = (v & 0xffff) << 1
    return sum(1 for i in range(16) if ((x >> i) & 1) != ((x >> (i + 1)) & 1))


def mulcost_table(internal):
    out = bytearray()
    for ang in range(256):
        a, b = struct.unpack_from("<hh", internal, 0x2890 + 4 * ang)
        out += struct.pack(">I", 2 * muls_n(a) + 2 * muls_n(b))
    return bytes(out)
