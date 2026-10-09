/*
 * Readable C model of the DDP2 IGS027A firmware behaviour (World v102 internal ROM +
 * v100_210.u23 external ROM), operating on the ARM's own memory layout.
 *
 * It is the human-readable specification for the 68000 port (hle/) and is verified
 * byte-exactly against the real firmware running in Unicorn (tools/armref.py) by
 * oracle/test_model.py. All addresses are ARM addresses; memory is little endian.
 *
 * Halfword field indices of an EST object ("o[n]" = halfword at o + 2n):
 *   0 state (0 free, 1 appear, 2 scripted, 3 vanish, 4/5 debris, 6/7 items)
 *   1 type id          2 sub type          3 x            4 y
 *   8 vx  9 vy (8.8)   10/11 sub-pixel accumulators
 *   12 angle (low byte) / item id (high byte, byte 0x19)   13 speed
 *   14/15 sprite x/y   16..19 sprite words (from animation tables)
 *   20 wait   21 counter   22 animation base   23 flag / limit   24 animation frame
 *   25 timer  26 anim period  27 anim countdown  28/29 script pointer (u32)
 *   30..33 type parameters (byte 0x3e/0x3f, 0x40/0x42 sprite offsets)
 */
#include <stdint.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int16_t s16;
typedef int32_t s32;

/* ------------------------------------------------------------------ memory */
static u8 ROMI[0x4000], ROME[0x20000], IRAM[0x400], WRAM[0x10000], SHARED[0x10000];
static u8 LATCH;
static int fault;           /* set on an access outside the modelled memory */

static u8 *P(u32 a)
{
	if (a < 0x4000) return ROMI + a;
	if (a - 0x08000000u < 0x20000) return ROME + (a - 0x08000000u);
	if (a - 0x10000000u < 0x400) return IRAM + (a - 0x10000000u);
	if (a - 0x18000000u < 0x10000) return WRAM + (a - 0x18000000u);
	if (a - 0x48000000u < 0x10000) return SHARED + (a - 0x48000000u);
	fault = 1;
	static u8 dummy[8];
	return dummy;
}
static u8 R8(u32 a) { return *P(a); }
static u16 R16(u32 a) { u8 *p = P(a); return p[0] | (p[1] << 8); }
static u32 R32(u32 a) { u8 *p = P(a); return p[0] | (p[1] << 8) | (p[2] << 16) | ((u32)p[3] << 24); }
static void W8(u32 a, u8 v) { *P(a) = v; }
static void W16(u32 a, u16 v) { u8 *p = P(a); p[0] = v; p[1] = v >> 8; }
static void W32(u32 a, u32 v) { u8 *p = P(a); p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

/* object field access */
#define F(o, n)       R16((o) + 2 * (n))
#define SF(o, n)      ((s16)R16((o) + 2 * (n)))
#define SETF(o, n, v) W16((o) + 2 * (n), (u16)(v))

/* ------------------------------------------------------------------ constants */
#define SYS        0x18000000u   /* EST system variables */
#define POOL       0x18000090u   /* 127 objects of 0x44 bytes */
#define POOL_LAST  (POOL + 0x10de * 2)
#define OBJ_SIZE   0x44u
#define REQS       0x18002290u   /* copied spawn requests, 24 bytes each */
#define GLOB       0x18002FA4u   /* cmd 09/0A parameters: [0..3] player pos, [4],[5] scroll, [7] y offset */
#define SINTAB     0x2890u       /* 256 x {s16 a, s16 b} */
#define AIMTAB     0x2C90u       /* 64 x 64 bytes */
#define TASKTAB    0x3C90u
#define T_ANIM     0x080063E4u   /* 8-byte sprite entries */
#define T_1714     0x0800010Cu
#define T_1718     0x08000100u
#define T_171C     0x08007C2Cu
#define T_1720     0x08006904u
#define T_172C     0x08007BECu   /* 4 x {s16, s16} debris velocities */
#define T_19C4     0x08007BFCu
#define T_19C8     0x08007C1Cu
#define T_1AE0     0x08007C0Cu
#define T_1AE4     0x08007C24u
#define T_TYPES    0x080085A0u   /* 8-byte type parameter records */
#define T_CTRLPTR  0x08000080u   /* -> table of script pointers */
#define T_CTRLMAX  0x08000084u   /* -> u16 count */

/* FIQ / system (external ROM) */
#define FIQ_STATE  0x18002E90u   /* s16 [0] error state, [0x88] in-FIQ flag */
#define SEQ        0x18003000u   /* u8 expected sequence */
#define SYSF       0x18002F90u   /* [0x0c] init done, [0x0e] reset request, [0x10] fiq busy */
#define TASKQ      0x18003004u   /* [0] read ptr, [4] write ptr, [8] u16 count */
#define TASKRING   0x1800320Cu
#define TASKRING_LAST 0x18003288u
#define MSGQ       0x18003010u   /* [0] read, [4] write, [8] out ptr, [0xc] u16 count */
#define MSGRING    0x1800328Cu

/* ------------------------------------------------------------------ helpers */
static u32 rng(void)              /* ext 0x08010CD8, additive lagged Fibonacci */
{
	const u32 base = 0x1800309Cu;  /* state[] at base - 0x7c = 0x18003020 */
	s32 j = (s32)R32(base + 100);
	s32 k = (s32)R32(base + 0x60);
	const u32 st = base - 0x7c;
	u32 v = R32(st + j * 4) + R32(st + k * 4);
	W32(st + j * 4, v);
	k -= 1;
	W32(base + 0x60, (u32)k);
	if (k < 0) {
		W32(base + 100, (u32)(j - 1));   /* no wrap check on this path (firmware quirk) */
		W32(base + 0x60, 0x36);
	} else {
		W32(base + 100, (u32)(j - 1));
		if (j - 1 < 0) W32(base + 100, 0x36);
	}
	return v & 0x7fffffff;
}

/* (s32)(a*b) rounded toward zero then >> 8, as the firmware does ("+0xff if negative") */
static u16 mul_shr8(s32 p) { if (p < 0) p += 0xff; return (u16)((u32)p >> 8); }

/* angle/speed -> velocity using the sine table */
static void set_velocity(u32 o, u32 angle, u16 speed)
{
	const u32 t = SINTAB + (angle & 0xff) * 4;
	SETF(o, 8, mul_shr8((s32)(s16)R16(t) * (s32)(u32)speed));
	SETF(o, 9, mul_shr8((s32)(u32)speed * (s32)(s16)R16(t + 2)));
}

/* anim base adjusted for direction when the type uses directional sprites (byte 0x3e) */
static void dir_anim(u32 o, u32 angle)
{
	if (R8(o + 0x3e) != 0)
		SETF(o, 0x16, F(o, 0x1e) + (u16)((((angle & 0xff) + 4) & 0xff) >> 3) * 4);
}

static void copy_sprite(u32 o, u32 entry)  /* 8 bytes -> fields 16..19 */
{
	W32(o + 0x20, R32(entry));
	W32(o + 0x24, R32(entry + 4));
}

static u32 find_free(void)                   /* from the rolling search pointer at SYS+0x88 */
{
	u32 o = R32(SYS + 0x88);
	for (int guard = 0; guard < 1000; guard++) {
		if (o > POOL_LAST) o = POOL;
		if (F(o, 0) == 0) return o;
		o += OBJ_SIZE;
	}
	fault = 2;                               /* firmware would hang here (pool full) */
	return POOL;
}

/* counters in SYS: +2 total, +4..+0x10 per category, +0x18/+0x1c removed-item list */
static void inc16(u32 a, int d) { W16(a, (u16)(R16(a) + d)); }

static void kill_350(u32 o) { inc16(SYS + 2, -1); inc16(SYS + 6, -1); SETF(o, 0, 0); }
static void kill_37c(u32 o) { inc16(SYS + 2, -1); inc16(SYS + 8, -1); SETF(o, 0, 0); }
static void halve_and_vanish(u32 o)
{
	SETF(o, 0, 3);
	SETF(o, 0x14, 6);
	SETF(o, 3, F(o, 3) - 5);
	SETF(o, 4, F(o, 4) - 8);
	SETF(o, 8, (s16)(SF(o, 8) / 2));
	SETF(o, 9, (s16)(SF(o, 9) / 2));
}
static void vanish_3a4(u32 o) { inc16(SYS + 6, -1); inc16(SYS + 8, 1); halve_and_vanish(o); }
static void vanish_40c(u32 o) { inc16(SYS + 4, -1); inc16(SYS + 8, 1); halve_and_vanish(o); }
static void push_removed(u32 o)
{
	u16 n = R16(SYS + 0x18);
	W16(SYS + 0x18, n + 1);
	W16(SYS + 0x1c + n * 2, R8(o + 0x19));
}
static void kill_474(u32 o) { inc16(SYS + 2, -1); inc16(SYS + 0xc, -1); push_removed(o); SETF(o, 0, 0); }
static void kill_4b4(u32 o) { inc16(SYS + 2, -1); inc16(SYS + 0xc, -1); inc16(SYS + 0xa, -1); push_removed(o); SETF(o, 0, 0); }
static void kill_500(u32 o) { inc16(SYS + 2, -1); inc16(SYS + 0x10, -1); SETF(o, 0, 0); }
static void kill_528(u32 o) { inc16(SYS + 2, -1); inc16(SYS + 0xa, -1); inc16(SYS + 0xe, -1); SETF(o, 0, 0); }

/* split a sub-pixel accumulator: keep |v| & 0xff (signed), return v rounded toward zero >> 8 */
static s16 split_acc(u32 o, int n, s32 v)
{
	s32 a = v < 0 ? -v : v;
	u16 keep = (u16)(a & 0xff);
	if (v < 0) { keep = (u16)-keep; v += 0xff; }
	SETF(o, n, keep);
	return (s16)((u32)v >> 8);
}

#include "est_model_engine.inc"
#include "est_model_spawn.inc"
#include "est_model_cmds.inc"
