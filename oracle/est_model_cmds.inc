/* Command handlers, FIQ bookkeeping, task loop and the exported API. */

#define SH16(off)       (0x48000000u + (off))

static void queues_reset(void)  /* ext $08010908 + $08010A64 */
{
	W32(TASKQ, TASKRING);
	W32(TASKQ + 4, TASKRING);
	W16(TASKQ + 8, 0);
	W32(MSGQ, MSGRING);
	W32(MSGQ + 4, MSGRING);
	W32(MSGQ + 8, 0x480002A0u);
	W16(MSGQ + 0xc, 0);
}

static void task_enqueue(u32 task)  /* ext $08010864 */
{
	if (R16(TASKQ + 8) < 0x20) {
		u32 w = R32(TASKQ + 4);
		W32(w, task);
		W32(TASKQ + 4, w == TASKRING + 0x7c ? TASKRING : w + 4);
		W16(TASKQ + 8, R16(TASKQ + 8) + 1);
	} else {
		fault = 8;   /* "TaskLog surcharge" */
	}
}

static void results_2340(void)
{
	u32 out = SH16(0x1500), o13 = SH16(0x0ec0), o5 = SH16(0x0880), o4 = SH16(0x07e0), l4 = SH16(0x3000);
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE) {
		u16 s = F(o, 0);
		if (s != 0) {
			u32 dst;
			if (s < 4) { dst = o13; o13 += 10; }
			else if (s == 5) { dst = o5; o5 += 10; }
			else if (s == 4) {
				dst = o4; o4 += 10;
				W16(l4, F(o, 1)); W16(l4 + 2, F(o, 3)); W16(l4 + 4, F(o, 4)); l4 += 6;
			} else {
				if (s > 7) fault = 9;
				dst = SH16(0x05e0) + (u32)R8(o + 0x19) * 10;
			}
			for (int i = 0; i < 5; i++) W16(dst + 2 * i, F(o, 0xe + i));
		}
		W32(out, R32(o));
		W32(out + 4, R32(o + 4));
		W16(out + 8, F(o, 4));
		out += 16;
	}
	for (int i = 0; i < 12; i++) W16(SH16(0x1f00) + 2 * i, R16(SYS + 2 * i));
	u16 n = R16(SYS + 0x18);
	if (n != 0) {
		W16(SH16(0x1f18), n);
		for (u16 i = 0; i < n; i++) W16(SH16(0x1f1c) + 2 * i, R16(SYS + 0x1c + 2 * i));
	}
}

static void est_start(u32 cont, int latch_count)  /* cmd 12 ($25D4) / cmd 13 ($2698) */
{
	if (R16(SYS + 0x80) != 0) fault = 10;
	for (int i = 0; i < 24; i += 4) W32(SYS + i, R32(SH16(0x1f00) + i));
	u32 n = (u32)R16(SYS) * 6;
	for (u32 i = 0; i < n; i++) W32(REQS + 4 * i, R32(SH16(0x1f80) + 4 * i));
	if (latch_count) W16(SYS + 0x1a, R16(SYS));
	W16(SYS + 0x18, 0);
	W16(SYS + 0x80, 1);
	W32(SYS + 0x8c, cont);
	task_enqueue(0x2280);
}

static void est_reset_2594(void)
{
	for (u32 o = POOL; o <= POOL_LAST; o += OBJ_SIZE) SETF(o, 0, 0);
	for (int i = 0; i < 0x90; i += 4) W32(SYS + i, 0);
	W32(SYS + 0x88, POOL);
}

static void msg_flush_04(void)  /* ext $08010A84 (no ARM messages are ever queued in normal play) */
{
	if (R32(MSGQ) != R32(MSGQ + 4)) fault = 11;
	W16(SH16(0x20), R16(MSGQ + 0xc));
	W32(MSGQ + 8, 0x480002A0u);
	W16(MSGQ + 0xc, 0);
}

static void dispatch(u16 cmd)
{
	switch (cmd) {
	case 0x01:
		if (R16(SYSF + 0xc) == 0) {
			if (R16(SYSF + 0x10) == 0) fault = 12;
			queues_reset();
			W16(SYSF + 0xc, 1);
		} else {
			W16(SYSF + 0xe, 1);
		}
		break;
	case 0x02: W16(SYSF + 0xe, 1); break;
	case 0x03: W16(SH16(0x20), R16(SYSF + 0xe) == 0); break;
	case 0x04: msg_flush_04(); break;
	case 0x09: W32(GLOB, R32(SH16(0x20))); W32(GLOB + 4, R32(SH16(0x24))); break;
	case 0x0a: W32(GLOB + 8, R32(SH16(0x20))); W32(GLOB + 12, R32(SH16(0x24))); break;
	case 0x11: est_reset_2594(); break;
	case 0x12: est_start(0x55c, 1); break;
	case 0x13: est_start(0x1730, 0); break;
	case 0x14: {
		u16 done = R16(SYS + 0x80) == 0;
		if (done) results_2340();
		W16(SH16(0x20), done);
		break;
	}
	case 0x16: case 0x17: W16(SH16(0x22), 0); break;   /* RAM tests pass */
	default: fault = 13; break;                          /* unused / untested command */
	}
}

/* FIQ entry ($08010488) followed by the task loop until idle ($08010984). Returns latch. */
static u8 command(u16 cmd, u8 seq)
{
	W16(SH16(0x10), cmd);
	LATCH = seq;
	W16(SYSF + 0x10, 1);
	u8 in = LATCH;
	LATCH = 0x80;
	if ((s16)R16(FIQ_STATE) == 0) {
		if (in == R8(SEQ)) {
			W8(SEQ, (R8(SEQ) + 1) & 0x7f);
		} else if (in == 0x80 && cmd == 1) {
			W8(SEQ, 1);             /* 68k (re)start handshake */
		} else {
			fault = 14;
			LATCH = 0x87;
			return LATCH;
		}
	} else {
		if (R16(FIQ_STATE) != 1 || in != 0x80 || cmd != 1) { fault = 15; return LATCH; }
		W16(FIQ_STATE, 0);
		W8(SEQ, 1);
	}
	if (cmd > 0x17) { fault = 16; LATCH = 0x88; return LATCH; }
	dispatch(cmd);
	W16(SYSF + 0x10, 0);
	W16(SH16(0x10), 0);
	LATCH = R8(SEQ);

	/* task loop */
	if (R16(SYSF + 0xc) != 0) {
		for (;;) {
			if (R16(SYSF + 0xe) != 0) { queues_reset(); W16(SYSF + 0xe, 0); continue; }
			if (R16(TASKQ + 8) == 0) break;
			u32 rp = R32(TASKQ);
			u32 task = R32(rp);
			if (task == 0) fault = 17;
			if (task == 0x2280) est_job(); else fault = 18;
			rp = R32(TASKQ);
			W32(TASKQ, rp < TASKRING_LAST ? rp + 4 : TASKRING);
			W16(TASKQ + 8, R16(TASKQ + 8) - 1);
		}
	}
	return LATCH;
}

/* ------------------------------------------------------------------ API (ctypes) */
void model_load_roms(const u8 *internal, const u8 *external)
{
	memcpy(ROMI, internal, sizeof ROMI);
	memcpy(ROME, external, sizeof ROME);
}

void model_set_state(const u8 *shared, const u8 *wram, const u8 *iram)
{
	memcpy(SHARED, shared, sizeof SHARED);
	memcpy(WRAM, wram, sizeof WRAM);
	memcpy(IRAM, iram, sizeof IRAM);
}

void model_get_state(u8 *shared, u8 *wram, u8 *iram)
{
	memcpy(shared, SHARED, sizeof SHARED);
	memcpy(wram, WRAM, sizeof WRAM);
	memcpy(iram, IRAM, sizeof IRAM);
}

int model_command(u16 cmd, u8 seq, int *fault_out)
{
	fault = 0;
	u8 r = command(cmd, seq);
	*fault_out = fault;
	return r;
}
