/* EST spawn / control requests (task table at internal ROM $3C90), param = request address. */

#define REQ(p, n) R16((p) + 2 * (n))

static void set_search(u32 next) { W32(SYS + 0x88, next); }

static void spawn_2064(u32 p)   /* id 0: scripted bullet */
{
	u32 o = find_free();
	SETF(o, 0, 1);
	u32 ang = REQ(p, 4) & 0xff;
	W8(o + 0x18, (u8)REQ(p, 4));
	u16 speed = REQ(p, 5);
	SETF(o, 0xd, speed);
	SETF(o, 0x14, 0);
	if (REQ(p, 1) > 0x34) fault = 4;                    /* MAX_ESTTYPE assertion */
	SETF(o, 1, REQ(p, 1));
	SETF(o, 2, REQ(p, 8));
	SETF(o, 0x15, REQ(p, 9));
	const u32 rec = T_TYPES + (u32)REQ(p, 1) * 8;
	W32(o + 0x3c, R32(rec));
	W32(o + 0x40, R32(rec + 4));
	u16 s = F(o, 0x1e);
	if (R8(o + 0x3e) != 0) s += (u16)(((ang + 4) & 0xff) >> 3) * 4;
	SETF(o, 0x16, s);
	SETF(o, 0x17, 0);
	if (R16(R32(T_CTRLMAX)) <= REQ(p, 0xb)) fault = 5;  /* MAX_ESTCTRL assertion */
	W32(o + 0x38, R32(R32(T_CTRLPTR) + (u32)REQ(p, 0xb) * 4));
	SETF(o, 0x18, R8(o + 0x3f));
	SETF(o, 0x19, REQ(p, 0xa));
	SETF(o, 0x1a, REQ(p, 7));
	SETF(o, 0x1b, 0);
	SETF(o, 3, REQ(p, 2));
	SETF(o, 4, REQ(p, 3));
	const u32 t = SINTAB + ang * 4;
	SETF(o, 8, mul_shr8((s32)(s16)R16(t) * (s32)(u32)speed));
	SETF(o, 9, mul_shr8((s32)(u32)speed * (s32)(s16)R16(t + 2)));
	u16 sp2 = REQ(p, 6);
	SETF(o, 10, mul_shr8((s32)(s16)R16(t) * (s32)(u32)sp2));
	SETF(o, 11, mul_shr8((s32)(u32)sp2 * (s32)(s16)R16(t + 2)));
	set_search(o + OBJ_SIZE);
}

static void kill_1f8c(u32 p) { SETF(POOL + (u32)REQ(p, 1) * OBJ_SIZE, 0, 0); }

static void vanish_1fa8(u32 p) { halve_and_vanish(POOL + (u32)REQ(p, 1) * OBJ_SIZE); }

static void set_sub_2004(u32 p) { SETF(POOL + (u32)REQ(p, 1) * OBJ_SIZE, 2, REQ(p, 6)); }

static void clear_low_1d54(u32 p)
{
	(void)p;
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE)
		if (F(o, 0) < 3) SETF(o, 0, 0);
}

static void vanish_all_1d80(u32 p)
{
	(void)p;
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE)
		if (F(o, 0) == 2) halve_and_vanish(o);
}

static void vanish_type_1df0(u32 p)
{
	u16 t = REQ(p, 1);
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE)
		if (F(o, 0) == 2 && F(o, 1) == t) vanish_3a4(o);
}

static void to_debris_1e34(u32 p)  /* turn every scripted bullet into falling debris (state 5) */
{
	const u16 t = REQ(p, 1);
	const u16 ox = R16(T_19C4 + (u32)t * 4), oy = R16(T_19C4 + (u32)t * 4 + 2);
	u32 frame = R16(SYS + 0x84) & 0xf;
	const u32 base = ((u32)t * 0x20 + 0x24) & 0xffff;
	const u16 lim = R16(T_19C8 + (u32)t * 2);
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE) {
		if (F(o, 0) == 2) {
			SETF(o, 0, 5);
			SETF(o, 1, t);
			SETF(o, 0x18, frame);
			SETF(o, 0x16, base);
			u16 c = (R16(SYS + 0x82) + 1);
			W16(SYS + 0x82, c);
			c &= 3;
			if (c == 0) {
				u16 n = R16(SYS + 0x84) + 1;
				W16(SYS + 0x84, n);
				frame = n & 0xf;
			} else {
				copy_sprite(o, T_ANIM + base * 8 + frame * 8);
				SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1800);
			}
			SETF(o, 0x1b, c);
			SETF(o, 8, c * 0x40 - 0x40);
			SETF(o, 9, (F(o, 9) & 0xf) - 7);
			SETF(o, 10, 0);
			SETF(o, 11, 0);
			SETF(o, 0x20, ox);
			SETF(o, 0x21, oy);
			SETF(o, 0x17, lim);
		} else if (F(o, 0) == 1) {
			SETF(o, 0, 0);
		}
	}
}

static void debris4_init(u32 o, u16 t, u16 x, u16 y, u16 anim)
{
	SETF(o, 0, 4);
	SETF(o, 1, t);
	u16 n = R16(SYS + 0x86) + 1;
	W16(SYS + 0x86, n);
	const u32 v = T_172C + (n & 3) * 4;
	SETF(o, 8, R16(v));
	u16 vy = R16(v + 2);
	if (R16(SYS + 0x86) & 1) vy = -vy;
	SETF(o, 9, vy);
	SETF(o, 3, x);
	SETF(o, 4, y);
	SETF(o, 10, 0);
	SETF(o, 11, 0);
	SETF(o, 0x19, 8);
	SETF(o, 0x18, 0);
	SETF(o, 0x16, anim);
	SETF(o, 0x1b, 0);
}

static void multi_debris_1bb0(u32 p)
{
	u16 t = REQ(p, 1), x = REQ(p, 2), y = REQ(p, 3);
	u32 o = R32(SYS + 0x88);
	for (u16 n = REQ(p, 6); n != 0; n--) {
		for (int guard = 0;; guard++) {
			if (o > POOL_LAST) o = POOL;
			if (F(o, 0) == 0) break;
			o += OBJ_SIZE;
			if (guard > 1000) { fault = 2; break; }
		}
		debris4_init(o, t, x, y, (u16)(t * 4 - 0x10));
		o += OBJ_SIZE;
	}
	set_search(o);
}

static void debris_1ae8(u32 p)
{
	u32 o = find_free();
	u16 t = REQ(p, 1);
	debris4_init(o, t, REQ(p, 2), REQ(p, 3), (u16)((t - 4) * 4));
	set_search(o + OBJ_SIZE);
}

static void falling_189c(u32 p)   /* state 5 */
{
	u32 o = find_free();
	SETF(o, 0, 5);
	u16 t = REQ(p, 1);
	SETF(o, 1, t);
	SETF(o, 0x18, R16(SYS + 0x84) & 0xf);
	SETF(o, 0x16, t * 0x20 + 0x24);
	u16 c = R16(SYS + 0x82) + 1;
	W16(SYS + 0x82, c);
	c &= 3;
	if (c == 0) {
		inc16(SYS + 0x84, 1);
	} else {
		copy_sprite(o, T_ANIM + (u32)F(o, 0x16) * 8 + (u32)F(o, 0x18) * 8);
		SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1800);
	}
	SETF(o, 3, REQ(p, 2));
	SETF(o, 4, REQ(p, 3));
	SETF(o, 8, c * 0x40 - 0x40);
	SETF(o, 9, (F(o, 9) & 0x3f) - 0x1f);
	SETF(o, 10, 0);
	SETF(o, 11, 0);
	SETF(o, 0x20, R16(T_19C4 + (u32)t * 4));
	SETF(o, 0x21, R16(T_19C4 + (u32)t * 4 + 2));
	SETF(o, 0x1b, c);
	SETF(o, 0x17, R16(T_19C8 + (u32)t * 2));
	set_search(o + OBJ_SIZE);
}

static void item6_1c94(u32 p)
{
	u32 o = find_free();
	SETF(o, 0, 6);
	SETF(o, 1, REQ(p, 1));
	W8(o + 0x19, (u8)REQ(p, 4));
	SETF(o, 3, REQ(p, 2));
	SETF(o, 4, REQ(p, 3));
	SETF(o, 0x1e, REQ(p, 5));
	SETF(o, 0x18, 0);
	SETF(o, 0x16, (u16)((REQ(p, 1) - 4) * 4));
	SETF(o, 0x1b, 0);
	SETF(o, 0x19, 1);
	set_search(o + OBJ_SIZE);
}

static void item7_19cc(u32 p)
{
	u32 o = find_free();
	SETF(o, 0, 7);
	u16 t = REQ(p, 1);
	SETF(o, 1, t);
	W8(o + 0x19, (u8)REQ(p, 4));
	SETF(o, 0x1e, REQ(p, 5));
	u16 n = R16(SYS + 0x84) + 1;
	W16(SYS + 0x84, n);
	SETF(o, 0x18, n & 0xf);
	SETF(o, 0x16, t * 0x20 + 0x34);
	u16 c = R16(SYS + 0x82) + 1;
	W16(SYS + 0x82, c);
	c &= 3;
	SETF(o, 0x1b, c);
	if (c != 0) {
		copy_sprite(o, T_ANIM + (u32)F(o, 0x16) * 8 + (u32)F(o, 0x18) * 8);
		SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1800);
	}
	SETF(o, 3, REQ(p, 2));
	SETF(o, 4, REQ(p, 3));
	SETF(o, 0x20, R16(T_1AE0 + (u32)t * 4));
	SETF(o, 0x21, R16(T_1AE0 + (u32)t * 4 + 2));
	SETF(o, 0x17, R16(T_1AE4 + (u32)t * 2));
	SETF(o, 0x19, 1);
	set_search(o + OBJ_SIZE);
}

static void remove_item_2020(u32 p)
{
	u32 o = POOL + (u32)REQ(p, 1) * OBJ_SIZE;
	if (F(o, 0) > 5) push_removed(o);
	SETF(o, 0, 0);
}

static void stop_bounce_1d28(u32 p)
{
	(void)p;
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE)
		if (F(o, 0) == 4) SETF(o, 0x19, 0);
}

static void (*const spawn_table[15])(u32) = {
	spawn_2064, kill_1f8c, vanish_1fa8, set_sub_2004, clear_low_1d54, vanish_all_1d80,
	vanish_type_1df0, to_debris_1e34, multi_debris_1bb0, debris_1ae8, falling_189c,
	item6_1c94, item7_19cc, remove_item_2020, stop_bounce_1d28,
};

static void est_job(void)        /* $2280 */
{
	u16 n = R16(SYS);
	u32 p = REQS;
	while (n != 0) {
		n--;
		u16 id = R16(p);
		if (id > 0xe) fault = 6;
		else spawn_table[id](p);
		p += 24;
	}
	W16(SYS, 0);
	u32 cont = R32(SYS + 0x8c);
	if (cont == 0x55c) est_update();
	else if (cont == 0x1730) est_animate();
	else fault = 7;
}
