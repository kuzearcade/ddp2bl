/*
 * Minimal 68000 test bench around Musashi, loaded from Python with ctypes.
 * Flat 16MB address space; ROM range is write-protected; accesses to the old
 * IGS027A window (0xD00000-0xD1FFFF) or other unexpected areas are recorded.
 */
#include <stdint.h>
#include <string.h>
#include "m68k.h"

#define MEMSIZE 0x1000000
#define RETURN_MAGIC 0x00FFFFF0u

static uint8_t mem[MEMSIZE];
static uint32_t rom_lo, rom_hi;            /* write-protected range */
static uint32_t ram_lo = 0x800000, ram_hi = 0x81ffff;
static int stopped;
static uint32_t bad_count, bad_first_addr, bad_first_pc, bad_first_kind;

static void bad(uint32_t addr, uint32_t kind)
{
	if (!bad_count++) { bad_first_addr = addr; bad_first_pc = m68k_get_reg(NULL, M68K_REG_PPC); bad_first_kind = kind; }
}

static int readable(uint32_t a) { return (a >= rom_lo && a <= rom_hi) || (a >= ram_lo && a <= ram_hi) || a >= 0xFFFF00; }

unsigned int m68k_read_memory_8(unsigned int a)  { a &= 0xffffff; if (!readable(a)) bad(a, 1); return mem[a]; }
unsigned int m68k_read_memory_16(unsigned int a) { a &= 0xffffff; if (!readable(a)) bad(a, 1); return (mem[a] << 8) | mem[a + 1]; }
unsigned int m68k_read_memory_32(unsigned int a) { return (m68k_read_memory_16(a) << 16) | m68k_read_memory_16(a + 2); }
unsigned int m68k_read_disassembler_16(unsigned int a) { a &= 0xffffff; return (mem[a] << 8) | mem[a + 1]; }
unsigned int m68k_read_disassembler_32(unsigned int a) { return (m68k_read_disassembler_16(a) << 16) | m68k_read_disassembler_16(a + 2); }

static void wr8(uint32_t a, uint8_t v)
{
	a &= 0xffffff;
	if (a >= ram_lo && a <= ram_hi) mem[a] = v;
	else bad(a, 2);
}
void m68k_write_memory_8(unsigned int a, unsigned int v)  { wr8(a, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v) { wr8(a, v >> 8); wr8(a + 1, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v) { m68k_write_memory_16(a, v >> 16); m68k_write_memory_16(a + 2, v); }

void instr_hook(unsigned int pc)
{
	if ((pc & 0xffffff) == RETURN_MAGIC) { stopped = 1; m68k_end_timeslice(); }
}

/* ------------------------------------------------------------------ API */
void m68r_init(uint32_t romlo, uint32_t romhi)
{
	memset(mem, 0, sizeof(mem));
	rom_lo = romlo; rom_hi = romhi;
	m68k_init();
	m68k_set_cpu_type(M68K_CPU_TYPE_68000);
	/* reset vectors are irrelevant: we call subroutines directly */
	m68k_pulse_reset();
}
void m68r_set_ram(uint32_t lo, uint32_t hi) { ram_lo = lo; ram_hi = hi; }
void m68r_load(uint32_t addr, const uint8_t *p, uint32_t n) { memcpy(mem + addr, p, n); }
void m68r_dump(uint32_t addr, uint8_t *p, uint32_t n) { memcpy(p, mem + addr, n); }
void m68r_set_reg(int r, uint32_t v) { m68k_set_reg((m68k_register_t)r, v); }
uint32_t m68r_get_reg(int r) { return m68k_get_reg(NULL, (m68k_register_t)r); }
uint32_t m68r_bad(uint32_t *addr, uint32_t *pc, uint32_t *kind) { *addr = bad_first_addr; *pc = bad_first_pc; *kind = bad_first_kind; return bad_count; }

/* Call the subroutine at pc with stack pointer sp. Returns cycles used, or -1 on timeout. */
int64_t m68r_call(uint32_t pc, uint32_t sp, int64_t max_cycles)
{
	int64_t total = 0;
	bad_count = 0;
	sp -= 4;
	mem[sp] = RETURN_MAGIC >> 24; mem[sp + 1] = RETURN_MAGIC >> 16; mem[sp + 2] = RETURN_MAGIC >> 8; mem[sp + 3] = RETURN_MAGIC;
	m68k_set_reg(M68K_REG_SR, 0x2700);
	m68k_set_reg(M68K_REG_SP, sp);
	m68k_set_reg(M68K_REG_PC, pc);
	stopped = 0;
	while (!stopped && total < max_cycles)
		total += m68k_execute(1000);
	if (!stopped) return -1;
	/* Musashi counts the cycles of the RTS that jumped to the magic address; that RTS is
	   part of the routine, but the hook fired before executing anything at the magic PC. */
	return total;
}
