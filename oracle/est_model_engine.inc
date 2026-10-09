/* EST engine: per-frame update (internal ROM $55C) and animation-only pass ($1730). */

/* sprite x/y words relative to an offset pair */
static void sprite_xy(u32 o, s32 x, s32 y, u16 ox, u16 oy)
{
	SETF(o, 0xe, ((u32)(x - ox) & 0x7ff) | 0x8000);
	SETF(o, 0xf, ((u32)(y - oy) & 0x3ff) | 0x8000);
}

/* countdown animation used by states 5 and 7: period 3, frames 15..0 */
static void anim_down(u32 o)
{
	if (F(o, 0x1b) != 0) { SETF(o, 0x1b, F(o, 0x1b) - 1); return; }
	SETF(o, 0x1b, 3);
	u16 f = F(o, 0x18);
	SETF(o, 0x18, f == 0 ? 0xf : f - 1);
	copy_sprite(o, T_ANIM + (u32)F(o, 0x16) * 8 + (u32)f * 8);
	SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1800);
}

/* countup animation used by states 4 and 6: period 5, frames 0..3 */
static void anim_up(u32 o)
{
	if (F(o, 0x1b) != 0) { SETF(o, 0x1b, F(o, 0x1b) - 1); return; }
	SETF(o, 0x1b, 5);
	u16 f = F(o, 0x18);
	SETF(o, 0x18, f < 3 ? f + 1 : 0);
	copy_sprite(o, T_ANIM + (u32)F(o, 0x16) * 8 + (u32)f * 8);
	SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1800);
}

static u8 aim_angle(int which, s32 x, s32 y)
{
	const u32 g = GLOB + (which ? 4 : 0);
	u32 dx = (u32)R16(g) - (u32)x;
	u32 dy = (u32)R16(g + 2) - (u32)y;
	u32 idx = (((dx + 0x200) & 0xffff) >> 4) * 0x40 + (((dy + 0x100) & 0xffff) >> 3);
	return R8(AIMTAB + idx);
}

static void state3(u32 o, u16 yoff);

/* state 2: script driven bullet */
static void state2(u32 o, u16 yoff)
{
	s16 dx = split_acc(o, 10, SF(o, 10));
	s16 dy = split_acc(o, 11, SF(o, 11));
	s32 x = (s16)(F(o, 3) + dx);
	s32 y = (s16)(F(o, 4) + dy + yoff);
	u16 timer;

	if (F(o, 0x19) != 0) {
		timer = F(o, 0x19) - 1;
		goto timer_done;
	}

	for (;;) {      /* script step; opcode 4 (loop) may jump back and re-execute */
		u32 pb = R32(o + 0x38);
		u16 op = R16(pb + 2);
		u16 a1 = R16(pb + 4), a2 = R16(pb + 6);
		u32 ang;
		switch (op) {
		case 0:
			kill_350(o);
			return;
		case 1:
			vanish_3a4(o);
			state3(o, yoff);
			return;
		case 2: SETF(o, 0x17, 1); break;
		case 3: SETF(o, 0x17, 0); break;
		case 4: {
			u16 c = F(o, 0x15);
			if (c == 0) {
				u8 b = R8(pb + 1);
				SETF(o, 0x15, b);
				if (b == 0) break;
			} else {
				SETF(o, 0x15, c - 1);
				if (c == 1) { SETF(o, 0x14, 0); goto advance; }
			}
			/* jump back a1 instructions and execute there now */
			if (a1 == 0) fault = 3;
			u32 np = R32(o + 0x38) - (u32)a1 * 8;
			W32(o + 0x38, np);
			SETF(o, 0x14, R8(np + 1));
			continue;
		}
		case 5: {
			const u32 rec = T_TYPES + (u32)a1 * 8;
			W32(o + 0x3c, R32(rec));
			W32(o + 0x40, R32(rec + 4));
			u16 s = F(o, 0x1e);
			if (R8(o + 0x3e) != 0) s += (u16)(((R8(o + 0x18) + 4) & 0xff) >> 3) * 4;
			SETF(o, 0x16, s);
			SETF(o, 0x18, R8(o + 0x3f));
			SETF(o, 0x1b, 0);
			break;
		}
		case 6: SETF(o, 0xd, F(o, 0xd) + a1); set_velocity(o, R8(o + 0x18), F(o, 0xd)); break;
		case 7: SETF(o, 0xd, F(o, 0xd) - a1); set_velocity(o, R8(o + 0x18), F(o, 0xd)); break;
		case 8: SETF(o, 0xd, a1); set_velocity(o, R8(o + 0x18), F(o, 0xd)); break;
		case 9:
			ang = (R8(o + 0x18) + a1) & 0xff;
			goto set_angle;
		case 0xa:
			ang = (R8(o + 0x18) - a1) & 0xff;
			goto set_angle;
		case 0xb:
			ang = a1 & 0xff;
			goto set_angle;
		case 0xc: {
			u16 sp = F(o, 0xd);
			u32 r = rng();
			ang = ((r & (u32)(a2 - 1)) + a1) & 0xff;
			W8(o + 0x18, ang);
			set_velocity(o, ang, sp);
			dir_anim(o, ang);
			break;
		}
		case 0xd: {
			u16 sp = F(o, 0xd);
			W8(o + 0x18, (u8)(R8(o + 0x18) - (a2 >> 1)));
			u32 r = rng();
			ang = ((r & (u32)(a2 - 1)) + R8(o + 0x18)) & 0xff;
			W8(o + 0x18, ang);
			set_velocity(o, ang, sp);
			dir_anim(o, ang);
			break;
		}
		case 0xe:
			W8(o + 0x18, (u8)a2);
			SETF(o, 0xd, a1);
			ang = R8(o + 0x18);
			set_velocity(o, ang, F(o, 0xd));
			dir_anim(o, ang);
			break;
		case 0xf: {
			u8 target = aim_angle(a1 != 0, x, y);
			u8 cur = R8(o + 0x18);
			if (cur != target) {
				u32 step = a2 & 0xff;
				if ((s32)((u32)target - cur) > 0x7f) step = (u32)-(s32)step;
				ang = (cur + step) & 0xff;
				W8(o + 0x18, ang);
				set_velocity(o, ang, F(o, 0xd));
				dir_anim(o, ang);
			}
			break;
		}
		case 0x10:
			ang = aim_angle(a1 != 0, x, y);
			W8(o + 0x18, ang);
			set_velocity(o, ang, F(o, 0xd));
			dir_anim(o, ang);
			break;
		case 0x11:
		case 0x12:
			break;
		case 0x13:
			SETF(o, 10, F(o, 10) + a1);
			SETF(o, 11, F(o, 11) + a2);
			break;
		default:
			timer = 0xffff;
			goto timer_done;
		}
		/* instruction done: repeat it, or advance to the next one */
		if (F(o, 0x14) == 0) {
advance:
			{
				u32 cp = R32(o + 0x38);
				pb = cp + 8;
				W32(o + 0x38, pb);
				SETF(o, 0x14, R8(cp + 9));
			}
		} else {
			SETF(o, 0x14, F(o, 0x14) - 1);
		}
		timer = R8(pb);
		goto timer_done;
set_angle:
		W8(o + 0x18, ang);
		set_velocity(o, ang, F(o, 0xd));
		dir_anim(o, ang);
		if (F(o, 0x14) == 0) goto advance;
		SETF(o, 0x14, F(o, 0x14) - 1);
		timer = R8(pb);
		goto timer_done;
	}

timer_done:
	SETF(o, 0x19, timer);
	if (!(y > -9 && y < 0xe8 && x > -9 && x <= 0x1c7) && F(o, 0x17) == 0) {
		kill_350(o);
		return;
	}
	sprite_xy(o, x, y, F(o, 0x20), F(o, 0x21));
	SETF(o, 3, x);
	SETF(o, 4, y);
	SETF(o, 10, F(o, 10) + F(o, 8));
	SETF(o, 11, F(o, 11) + F(o, 9));
	if (F(o, 0x1b) == 0) {
		SETF(o, 0x1b, F(o, 0x1a));
		u16 f = F(o, 0x18);
		SETF(o, 0x18, f == 0 ? R8(o + 0x3f) : f - 1);
		copy_sprite(o, T_1714 + (u32)F(o, 0x16) * 8 - (u32)f * 8);
		SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1700);
	} else {
		SETF(o, 0x1b, F(o, 0x1b) - 1);
	}
}

/* state 3: vanish animation */
static void state3(u32 o, u16 yoff)
{
	if (F(o, 0x14) == 0) { kill_37c(o); return; }
	u16 w = F(o, 0x14) - 1;
	SETF(o, 0x14, w);
	s16 dx = split_acc(o, 10, SF(o, 10));
	s16 dy = split_acc(o, 11, SF(o, 11));
	u16 x = F(o, 3) + dx;
	u16 y = F(o, 4) + dy + yoff;
	copy_sprite(o, 0x08000134u - (u32)w * 8);
	SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1700);
	SETF(o, 0xe, (x & 0x7ff) | 0x8000);
	SETF(o, 0xf, (y & 0x3ff) | 0x8000);
	SETF(o, 3, x);
	SETF(o, 4, y);
	SETF(o, 10, F(o, 10) + F(o, 8));
	SETF(o, 11, F(o, 11) + F(o, 9));
}

/* state 1: appear */
static void state1(u32 o, u16 yoff)
{
	if (F(o, 0x19) != 0) {
		SETF(o, 0x19, F(o, 0x19) - 1);
		if (F(o, 0x14) == 0) SETF(o, 0x14, 1);
		else SETF(o, 4, F(o, 4) + yoff);
		if (F(o, 2) == 0) {
			W32(o + 0x1c, R32(T_1718));
			W32(o + 0x20, R32(T_1718 + 4));
			W32(o + 0x24, R32(T_1718 + 8));
		} else {
			u32 idx;
			if (F(o, 2) == 2) {
				idx = F(o, 0x15);
				SETF(o, 0x15, F(o, 0x15) + 1);
			} else {
				u16 n = R16(SYS + 0x16) + 1;
				W16(SYS + 0x16, n);
				idx = ((u32)F(o, 0x15) * 0x80 + (((R8(o + 0x18) + 4) & 0xff) >> 3) * 4 + (n & 3)) & 0xffff;
			}
			const u32 p = T_171C + idx * 4;
			copy_sprite(o, T_1720 + idx * 8);
			SETF(o, 0x10, (F(o, 0x10) & 0xe0ff) | 0x1700);
			SETF(o, 0xe, ((u16)(F(o, 3) - R16(p)) & 0x7ff) | 0x8000);
			SETF(o, 0xf, ((u16)(F(o, 4) - R16(p + 2)) & 0x3ff) | 0x8000);
		}
		return;
	}
	if (F(o, 0x14) == 0) SETF(o, 4, F(o, 4) - yoff);
	if (R16(SYS + 0x14) != 0) {
		vanish_40c(o);
		state3(o, yoff);
		return;
	}
	u32 pb = R32(o + 0x38);
	if (pb == 0) {
		SETF(o, 0x19, 0xffff);
	} else {
		SETF(o, 0x14, R8(pb + 1));
		SETF(o, 0x19, R8(pb));
		SETF(o, 0x15, 0);
	}
	SETF(o, 2, 0);
	SETF(o, 0, 2);
	inc16(SYS + 6, 1);
	inc16(SYS + 4, -1);
	state2(o, yoff);
}

/* bounce helpers for state 4 */
static u32 next_debris_vel(u32 o)
{
	SETF(o, 0x19, F(o, 0x19) - 1);
	u16 n = R16(SYS + 0x86) + 1;
	W16(SYS + 0x86, n);
	return T_172C + (n & 3) * 4;
}

/* state 4: bouncing debris */
static void state4(u32 o, u16 yoff)
{
	s32 vx = SF(o, 8), vy = SF(o, 9);
	s16 dx = split_acc(o, 10, (s16)(F(o, 10) + vx));
	s16 dy = split_acc(o, 11, (s16)(F(o, 11) + vy));
	s32 x = (s16)(F(o, 3) + dx);
	SETF(o, 3, x);
	s32 y = (s16)(F(o, 4) + dy + yoff);
	SETF(o, 4, y);

	if (F(o, 0x19) != 0) {
		u32 p;
		if (vx < 1) {
			if (x <= 0xe) {             /* bounce off the left edge */
				p = next_debris_vel(o);
				SETF(o, 8, R16(p));
				SETF(o, 9, -R16(p + 2));
				goto draw;
			}
		} else if (x >= 0x1b2) {        /* bounce off the right edge */
			p = next_debris_vel(o);
			SETF(o, 8, -R16(p));
			SETF(o, 9, R16(p + 2));
			goto draw;
		}
		if (vy < 1) {
			if (y < 0xd) {
				p = next_debris_vel(o);
				SETF(o, 8, R16(p));
				SETF(o, 9, R16(p + 2));
			}
		} else if (y > 0xd3) {
			p = next_debris_vel(o);
			SETF(o, 8, -R16(p));
			SETF(o, 9, -R16(p + 2));
		}
		goto draw;
	}
	/* no bounces left: die once off screen */
	if (vx < 1 ? x > -0xe : x < 0x1ce) {
		if (vy < 1 ? y > -0xc : y < 0xec) goto draw;
	}
	kill_528(o);
	return;
draw:
	SETF(o, 0xe, ((u32)(x - 0xe) & 0x7ff) | 0x8000);
	SETF(o, 0xf, ((u32)(y - 0xf) & 0x3ff) | 0x8000);
	anim_up(o);
}

/* state 5: falling debris */
static void state5(u32 o, u16 yoff)
{
	s16 dx = split_acc(o, 10, (s16)(F(o, 10) + F(o, 8)));
	s16 dy = split_acc(o, 11, (s16)(F(o, 11) + F(o, 9)));
	s16 x = (s16)(F(o, 3) + dx);
	SETF(o, 3, x);
	if (x <= SF(o, 0x17)) { kill_500(o); return; }
	SETF(o, 8, F(o, 8) - 0x10);
	SETF(o, 4, F(o, 4) + dy + yoff);
	SETF(o, 0xe, ((u16)(F(o, 3) - F(o, 0x20)) & 0x7ff) | 0x8000);
	SETF(o, 0xf, ((u16)(F(o, 4) - F(o, 0x21)) & 0x3ff) | 0x8000);
	anim_down(o);
}

/* states 6/7: items scrolling with the background */
static void item_move(u32 o, u16 yoff)
{
	if (F(o, 0x19) == 0) {
		u16 s = (F(o, 0x1e) == 2) ? R16(GLOB + 10) : R16(GLOB + 8);
		SETF(o, 3, F(o, 3) + s);
		SETF(o, 4, F(o, 4) + yoff);
	} else {
		SETF(o, 0x19, 0);
	}
}

static void state6(u32 o, u16 yoff)
{
	item_move(o, yoff);
	if (SF(o, 3) > -0xe) {
		SETF(o, 0xe, ((u16)(F(o, 3) - 0xe) & 0x7ff) | 0x8000);
		SETF(o, 0xf, ((u16)(F(o, 4) - 0xf) & 0x3ff) | 0x8000);
		anim_up(o);
	} else {
		kill_4b4(o);
	}
}

static void state7(u32 o, u16 yoff)
{
	item_move(o, yoff);
	if (SF(o, 3) <= SF(o, 0x17)) { kill_474(o); return; }
	SETF(o, 0xe, ((u16)(F(o, 3) - F(o, 0x20)) & 0x7ff) | 0x8000);
	SETF(o, 0xf, ((u16)(F(o, 4) - F(o, 0x21)) & 0x3ff) | 0x8000);
	anim_down(o);
}

static void est_update(void)      /* $55C */
{
	const u16 yoff = R16(GLOB + 14);
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE) {
		switch (F(o, 0)) {
		case 1: state1(o, yoff); break;
		case 2: state2(o, yoff); break;
		case 3: state3(o, yoff); break;
		case 4: state4(o, yoff); break;
		case 5: state5(o, yoff); break;
		case 6: state6(o, yoff); break;
		case 7: state7(o, yoff); break;
		default: break;
		}
	}
	if (R16(SYS + 0x12) != 0) inc16(SYS + 0x12, -1);
	if (R16(SYS + 0x14) != 0) inc16(SYS + 0x14, -1);
	W16(SYS + 0x80, 0);
}

static void est_animate(void)     /* $1730 */
{
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE) {
		switch (F(o, 0)) {
		case 4: case 6: anim_up(o); break;
		case 5: case 7: anim_down(o); break;
		default: break;
		}
	}
	W16(SYS + 0x80, 0);
}
