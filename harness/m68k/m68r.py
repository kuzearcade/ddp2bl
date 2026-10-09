"""ctypes wrapper for libm68r.so (Musashi 68000 test bench)."""
import ctypes
import os

_lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "libm68r.so"))
_lib.m68r_call.restype = ctypes.c_int64
_lib.m68r_call.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int64]
_lib.m68r_get_reg.restype = ctypes.c_uint32
_lib.m68r_bad.restype = ctypes.c_uint32

# Musashi register ids
D0, D1, D2, D3, D4, D5, D6, D7, A0, A1, A2, A3, A4, A5, A6, A7, PC, SR = range(18)


class M68k:
    def __init__(self, rom_lo=0x000000, rom_hi=0x4fffff, ram_lo=0x800000, ram_hi=0x81ffff):
        _lib.m68r_init(rom_lo, rom_hi)
        _lib.m68r_set_ram(ram_lo, ram_hi)

    def load(self, addr, data):
        data = bytes(data)
        _lib.m68r_load(ctypes.c_uint32(addr), data, len(data))

    def dump(self, addr, n):
        buf = ctypes.create_string_buffer(n)
        _lib.m68r_dump(ctypes.c_uint32(addr), buf, n)
        return buf.raw

    def set_reg(self, r, v):
        _lib.m68r_set_reg(r, ctypes.c_uint32(v & 0xffffffff))

    def reg(self, r):
        return _lib.m68r_get_reg(r)

    def call(self, pc, sp=0x81fff0, max_cycles=50_000_000):
        """Run subroutine at pc; returns 68000 cycles (Musashi timing). Raises on bad access."""
        cyc = _lib.m68r_call(pc, sp, max_cycles)
        a, p, k = ctypes.c_uint32(), ctypes.c_uint32(), ctypes.c_uint32()
        n = _lib.m68r_bad(ctypes.byref(a), ctypes.byref(p), ctypes.byref(k))
        if n:
            raise RuntimeError("%d bad accesses, first %s %06x at pc %06x" % (
                n, "read" if k.value == 1 else "write", a.value, p.value))
        if cyc < 0:
            raise RuntimeError("timeout")
        return cyc
