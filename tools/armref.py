#!/usr/bin/env python3
"""Reference model of the DDP2 IGS027A: the real ARM firmware executed in Unicorn.

The model holds the ARM-visible memory (shared RAM, work RAM, IRAM) and executes:
  * command(cmd, seq): the FIQ handler as the 68k latch write triggers it, then the
    main loop until it is idle again (so background EST jobs run to completion);
  * the result is the new memory state plus statistics (instructions executed in the
    handler and in background jobs).

It is used (1) to validate itself against MAME captures (tools/validate_armref.py),
and (2) as the oracle for the 68000 replacement code (harness/hle_test.py).
"""
import struct

from unicorn import Uc, UcError, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_CODE, UC_HOOK_MEM_UNMAPPED
from unicorn.arm_const import (UC_ARM_REG_PC, UC_ARM_REG_LR, UC_ARM_REG_SP, UC_ARM_REG_CPSR,
                               UC_ARM_REG_R0, UC_ARM_REG_R12)

INT_BASE, INT_SIZE = 0x00000000, 0x4000
EXT_BASE, EXT_SIZE = 0x08000000, 0x20000
IRAM_BASE, IRAM_SIZE = 0x10000000, 0x400
WRAM_BASE, WRAM_SIZE = 0x18000000, 0x10000
LATCH_BASE = 0x38000000
SHARED_BASE, SHARED_SIZE = 0x48000000, 0x10000
XOR_BASE = 0x50000000

FIQ_HANDLER = 0x08010488          # Thumb
TASK_LOOP = 0x08010984            # Thumb, never returns
IDLE_PC = 0x080109B4              # task loop polling point (queue empty)
RETURN_MAGIC = 0x0FFFFF00         # LR used for direct calls; execution stops there
FIQ_STACK = 0x18007F00            # scratch stack for handler calls (excluded from comparisons)
MAIN_STACK = 0x18007D80

QUEUE_COUNT = 0x1800300C          # u16 pending tasks
FLAG_RESET = 0x18002F9E           # u16 set by cmd 2
FLAG_INIT = 0x18002F9C            # u16 set by cmd 1; the task loop spins until it is set


class ArmRef:
    def __init__(self, internal_rom, external_rom_decrypted):
        self.uc = uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
        uc.mem_map(INT_BASE, INT_SIZE)
        uc.mem_write(INT_BASE, internal_rom)
        uc.mem_map(EXT_BASE, EXT_SIZE)
        uc.mem_write(EXT_BASE, external_rom_decrypted)
        uc.mem_map(IRAM_BASE, 0x1000)
        uc.mem_map(WRAM_BASE, WRAM_SIZE)
        uc.mem_map(LATCH_BASE, 0x1000)
        uc.mem_map(SHARED_BASE, SHARED_SIZE)
        uc.mem_map(XOR_BASE, 0x1000)
        uc.mem_map(RETURN_MAGIC & ~0xfff, 0x1000)
        self.insns = 0
        self.main_ctx = None
        self.stop_at_idle = False
        uc.hook_add(UC_HOOK_CODE, self._count)

    def _count(self, uc, addr, size, user):
        if self.stop_at_idle and addr == IDLE_PC and self.u16(QUEUE_COUNT) == 0 and self.u16(FLAG_RESET) == 0:
            uc.emu_stop()
            return
        self.insns += 1

    # ----------------------------------------------------------------- state
    def load_state(self, shared, wram, iram):
        self.uc.mem_write(SHARED_BASE, bytes(shared))
        self.uc.mem_write(WRAM_BASE, bytes(wram))
        self.uc.mem_write(IRAM_BASE, bytes(iram[:IRAM_SIZE]))

    def state(self):
        return (self.uc.mem_read(SHARED_BASE, SHARED_SIZE),
                self.uc.mem_read(WRAM_BASE, WRAM_SIZE),
                self.uc.mem_read(IRAM_BASE, IRAM_SIZE))

    def latch(self):
        return self.uc.mem_read(LATCH_BASE, 1)[0]

    def u16(self, addr):
        return struct.unpack("<H", self.uc.mem_read(addr, 2))[0]

    # ----------------------------------------------------------------- execution
    def _call(self, addr, thumb, sp, max_insns=50_000_000):
        uc = self.uc
        uc.reg_write(UC_ARM_REG_SP, sp)
        uc.reg_write(UC_ARM_REG_LR, RETURN_MAGIC)
        start = self.insns
        uc.emu_start(addr | (1 if thumb else 0), RETURN_MAGIC, count=max_insns)
        if uc.reg_read(UC_ARM_REG_PC) & ~1 != RETURN_MAGIC:
            raise RuntimeError("call %08x did not return (pc=%08x)" % (addr, uc.reg_read(UC_ARM_REG_PC)))
        return self.insns - start

    def _run_main_until_idle(self, max_insns=50_000_000):
        """Resume (or start) the task loop and stop when it is idle with an empty queue."""
        uc = self.uc
        if self.main_ctx is None and self.u16(FLAG_INIT) == 0:
            return 0  # task loop still waiting for cmd 1; nothing can run yet
        if self.main_ctx is None:
            uc.reg_write(UC_ARM_REG_SP, MAIN_STACK)
            pc = TASK_LOOP | 1
        else:
            uc.context_restore(self.main_ctx)
            pc = uc.reg_read(UC_ARM_REG_PC) | (1 if uc.reg_read(UC_ARM_REG_CPSR) & 0x20 else 0)
        start = self.insns
        self.stop_at_idle = True
        try:
            uc.emu_start(pc, 0xFFFFFFFF, count=max_insns)
        finally:
            self.stop_at_idle = False
        cur = uc.reg_read(UC_ARM_REG_PC) & ~1
        if cur != IDLE_PC:
            raise RuntimeError("main loop stopped at %08x" % cur)
        self.main_ctx = uc.context_save()
        return self.insns - start

    def boot_main_loop(self):
        """Bring the task loop to its idle point (call once after loading a state)."""
        self.main_ctx = None
        return self._run_main_until_idle()

    def command(self, cmd, seq):
        """68k wrote cmd to $D00010 and seq to the latch: run FIQ handler + background work."""
        self.uc.mem_write(SHARED_BASE + 0x10, struct.pack("<H", cmd))
        self.uc.mem_write(LATCH_BASE, bytes([seq]))
        n_fiq = self._call(FIQ_HANDLER, True, FIQ_STACK)
        reply = self.latch()
        n_bg = self._run_main_until_idle()
        return reply, n_fiq, n_bg


def load_roms(arm_dir):
    with open(arm_dir + "/internal.bin", "rb") as f:
        internal = f.read()
    with open(arm_dir + "/external_dec.bin", "rb") as f:
        external = f.read()
    return internal, external
