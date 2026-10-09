#!/usr/bin/env python3
"""Convert the pixel section of a harness state dump to PNG (stdlib only)."""
import struct
import sys
import zlib


def sections(path):
    d = open(path, "rb").read()
    pos, out = 0, []
    while pos < len(d):
        (n,) = struct.unpack_from("<I", d, pos)
        out.append(d[pos + 4:pos + 4 + n])
        pos += 4 + n
    return out


def write_png(pixels, w, h, path, rotate=True):
    # pixels: BGRA u32 little-endian per MAME screen:pixels()
    px = [pixels[i:i + 4] for i in range(0, len(pixels), 4)]
    if rotate:  # ddp2 is ROT270: show it upright
        rows = [[px[y * w + x] for y in range(h)] for x in range(w - 1, -1, -1)]
        w, h = h, w
    else:
        rows = [px[y * w:(y + 1) * w] for y in range(h)]
    raw = b"".join(b"\x00" + b"".join(bytes((p[2], p[1], p[0])) for p in r) for r in rows)
    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


if __name__ == "__main__":
    secs = sections(sys.argv[1])
    pix = secs[5]
    w, h = 448, len(pix) // 4 // 448
    write_png(pix, w, h, sys.argv[2])
