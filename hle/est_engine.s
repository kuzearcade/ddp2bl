; ---------------------------------------------------------------------------
; EST engine: per-frame update (ARM $55C) and animation-only pass (ARM $1730)
; Registers inside the object loop:
;   a0 = object, d7 = y scroll offset (GLOB word 7), d6 = slot counter,
;   a4 = SHWIN, a5 = HLEV, a3 = cycle accumulator. State routines may use d0-d5, a1, a2, a6.
; ---------------------------------------------------------------------------

; SPLIT v, field, t1, t2 : v.w = accumulator value (s16)
;   field(a0) <- remainder (sign of v), v <- quotient (truncated toward 0)
SPLIT		macro
		move.w	\1,\3
		bpl.s	.p\@
		addi.w	#$ff,\1		; v < 0: q = (v + 255) >> 8, r = v - (v + 255 & $ff00)
		move.w	\1,\4
		andi.w	#$ff00,\4
		sub.w	\4,\3
		bra.s	.s\@
.p\@:		andi.w	#$ff,\3		; v >= 0: q = v >> 8, r = v & $ff
.s\@:		move.w	\3,\2(a0)
		asr.w	#8,\1
		endm

; SPLITV v, vel, acc, t1, t2 : SPLIT with the next frame's velocity added in place
;   acc(a0) <- remainder + vel(a0), v <- quotient
SPLITV		macro
		move.w	\1,\4
		bpl.s	.p\@
		addi.w	#$ff,\1
		move.w	\1,\5
		andi.w	#$ff00,\5
		sub.w	\5,\4
		bra.s	.s\@
.p\@:		andi.w	#$ff,\4
.s\@:		add.w	\2(a0),\4
		move.w	\4,\3(a0)
		asr.w	#8,\1
		endm

; SPRXY x, y, ox, oy, t : sprite position words
SPRXY		macro
		move.w	\1,\5
		sub.w	\3,\5
		andi.w	#$7ff,\5
		ori.w	#$8000,\5
		move.w	\5,O_SPRX(a0)
		move.w	\2,\5
		sub.w	\4,\5
		andi.w	#$3ff,\5
		ori.w	#$8000,\5
		move.w	\5,O_SPRY(a0)
		endm

; The object loop accounts for itself: every slot is charged UPD_DEAD up front, a live
; slot adds UPD_LIVE-UPD_DEAD (its state routine accounts for itself, rts included), a
; slot above state 7 (skipped, as by the firmware) adds UPD_HIGH-UPD_DEAD.
;   dead   8 + 10 + 8 + 10                                    = 36
;   live   8 + 8 + 8 + 8 + 8 + 4 + 14 + 22 + 8 + 10            = 98
;   high   8 + 8 + 8 + 10 + 8 + 10 + 8 + 10                    = 70
; plus the entry bra.s (10) and 4 for the last dbra (falls through: 14).
UPD_DEAD	equ	36
UPD_LIVE	equ	98
UPD_HIGH	equ	70

est_update:
	move.w	GLOB+14(a5),d7
	lea	POOL(a5),a0
	moveq	#NOBJ-1,d6
	lea	NOBJ*UPD_DEAD+10+4(a3),a3	; @cyc-adjust
	; @cyc-off
	bra.s	.loop			; 10
.high:	lea	UPD_HIGH-UPD_DEAD(a3),a3	;  8  @cyc-adjust
	bra.s	.next			; 10
.loop:	move.w	(a0),d0			;  8
	beq.s	.next			; 10 / 8
	cmpi.w	#7,d0			;  8
	bhi.s	.high			; 10 / 8
	lea	UPD_LIVE-UPD_DEAD(a3),a3	;  8  @cyc-adjust
	add.w	d0,d0			;  4
	move.w	.tab-2(pc,d0.w),d0	; 14
	jsr	.tab(pc,d0.w)		; 22
.next:	lea	OBJ_SIZE(a0),a0		;  8
	dbra	d6,.loop		; 10 / 14
	; @cyc-on
	tst.w	SYS+$12(a5)
	beq.s	.t1
	subq.w	#1,SYS+$12(a5)
.t1:	tst.w	SYS+$14(a5)
	beq.s	.t2
	subq.w	#1,SYS+$14(a5)
.t2:	clr.w	SYS+S_BUSY(a5)
	rts
.tab:	dc.w	st1-.tab, st2-.tab, st3-.tab, st4-.tab, st5-.tab, st6-.tab, st7-.tab

est_animate:
	lea	POOL(a5),a0
.loop:	move.w	(a0),d0
	cmpi.w	#4,d0
	bcs.s	.next
	beq.s	.up
	cmpi.w	#6,d0
	beq.s	.up
	cmpi.w	#7,d0
	bhi.s	.next
	bsr	anim_down		; 5, 7
	bra.s	.next
.up:	bsr	anim_up			; 4, 6
.next:	lea	OBJ_SIZE(a0),a0
	cmpa.l	#HLEV+POOL+(NOBJ-1)*OBJ_SIZE,a0
	bls.s	.loop
	clr.w	SYS+S_BUSY(a5)
	rts

; ---------------------------------------------------------------------------
; animation helpers
; ---------------------------------------------------------------------------
anim_down:				; period 3, frames 15..0 (states 5, 7)
	subq.w	#1,O_ACNT(a0)		; counter at 0: it wraps (carry), reload below
	bcs.s	.f			; @unlikely
	rts
.f:	move.w	#3,O_ACNT(a0)
	move.w	O_AFRAME(a0),d0
	move.w	d0,d1
	subq.w	#1,d1
	bcc.s	.s
	moveq	#$f,d1
.s:	move.w	d1,O_AFRAME(a0)
	bra	copy_anim_1800		; frame = old value (d0)

anim_up:				; period 5, frames 0..3 (states 4, 6)
	subq.w	#1,O_ACNT(a0)
	bcs.s	.f			; @unlikely
	rts
.f:	move.w	#5,O_ACNT(a0)
	move.w	O_AFRAME(a0),d0
	moveq	#0,d1
	cmpi.w	#3,d0
	bcc.s	.s
	move.w	d0,d1
	addq.w	#1,d1
.s:	move.w	d1,O_AFRAME(a0)
	bra	copy_anim_1800

; dir_anim: if the type has directional sprites, ABASE = P1E + 4*(((ang+4)&$ff)>>3)
; in: d0.w = angle (0..255); clobbers d1
dir_anim:
	tst.b	O_DIRANIM(a0)
	beq.s	.x
	move.w	d0,d1
	addq.w	#4,d1
	andi.w	#$ff,d1
	lsr.w	#3,d1
	add.w	d1,d1
	add.w	d1,d1
	add.w	O_P1E(a0),d1
	move.w	d1,O_ABASE(a0)
.x:	rts

; rng: additive lagged Fibonacci (ARM $08010CD8) -> d0.l; clobbers d1, d2, a1
rng:
	lea	RNG_S(a5),a1
	move.l	RNG_J(a5),d1
	move.l	RNG_K(a5),d2
	add.l	d1,d1
	add.l	d1,d1
	add.l	d2,d2
	add.l	d2,d2
	move.l	(a1,d1.l),d0
	add.l	(a1,d2.l),d0
	move.l	d0,(a1,d1.l)
	asr.l	#2,d1
	asr.l	#2,d2
	subq.l	#1,d1			; j - 1
	subq.l	#1,d2			; k - 1
	bpl.s	.kok
	move.l	d1,RNG_J(a5)		; no wrap check on this path (firmware quirk)
	moveq	#$36,d2
	move.l	d2,RNG_K(a5)
	bra.s	.x
.kok:	move.l	d2,RNG_K(a5)
	tst.l	d1
	bpl.s	.jok
	moveq	#$36,d1
.jok:	move.l	d1,RNG_J(a5)
.x:	andi.l	#$7fffffff,d0
	rts

; aim: target angle towards player (d2 = 0: GLOB[0..1], else GLOB[2..3])
; from x d4, y d5 -> d0.w (0..255); clobbers d1, d2, a1
aim:
	lea	GLOB(a5),a1
	tst.w	d2
	beq.s	.p
	addq.l	#4,a1
.p:	move.w	(a1)+,d0
	sub.w	d4,d0
	addi.w	#$200,d0
	lsr.w	#4,d0			; row (0..$fff)
	move.w	(a1),d1
	sub.w	d5,d1
	addi.w	#$100,d1
	lsr.w	#3,d1			; column (0..$1fff)
	ext.l	d0
	andi.l	#$ffff,d0
	lsl.l	#6,d0
	andi.l	#$ffff,d1
	add.l	d1,d0			; index into the table at ARM $2C90
	cmpi.l	#AIMTAB_SIZE,d0		; beyond the internal ROM: MAME reads 0
	bcc.s	.zero
	lea	AIMTAB,a1
	move.b	(a1,d0.l),d0
	andi.w	#$ff,d0
	rts
.zero:	moveq	#0,d0
	rts

; ---------------------------------------------------------------------------
; state 2: scripted bullet
; ---------------------------------------------------------------------------
st2:
	move.w	O_TIMER(a0),d0
	beq	st2_script		; @unlikely
	; Fast path (instruction still running): st2_timer's work with the velocity added
	; to the remainder while it is in a register (taken back if the bullet dies), and
	; the four bounds as two unsigned ranges: -9 < y < $E8, -9 < x <= $1C7.
	subq.w	#1,d0
	move.w	d0,O_TIMER(a0)
	move.w	O_AX(a0),d4
	SPLITV	d4,O_VX,O_AX,d0,d1
	move.w	O_AY(a0),d5
	SPLITV	d5,O_VY,O_AY,d0,d1
	add.w	O_X(a0),d4		; x
	add.w	O_Y(a0),d5
	add.w	d7,d5			; y
	move.w	d5,d0
	addq.w	#8,d0
	cmpi.w	#$e8+8,d0
	bcc.s	.off			; @unlikely
	move.w	d4,d0
	addq.w	#8,d0
	cmpi.w	#$1c8+8,d0
	bcc.s	.off			; @unlikely
.on:	SPRXY	d4,d5,O_OX(a0),O_OY(a0),d0
	move.w	d4,O_X(a0)
	move.w	d5,O_Y(a0)
	subq.w	#1,O_ACNT(a0)		; counter at 0: it wraps (carry), reloaded by st2_frame
	bcs	st2_frame		; @unlikely
	rts
.off:	tst.w	O_FLAG(a0)
	bne.s	.on
	move.w	O_VX(a0),d0		; dies: the remainder as the firmware leaves it
	sub.w	d0,O_AX(a0)
	move.w	O_VY(a0),d0
	sub.w	d0,O_AY(a0)
	bra	op_kill
st2_script:
	move.w	O_AX(a0),d4
	SPLIT	d4,O_AX,d0,d1
	move.w	O_AY(a0),d5
	SPLIT	d5,O_AY,d0,d1
	add.w	O_X(a0),d4		; x
	add.w	O_Y(a0),d5
	add.w	d7,d5			; y
	movea.l	O_SCRIPT(a0),a1
st2_exec:
	move.w	2(a1),d0		; opcode
	cmpi.w	#$13,d0
	bhi.s	.bad
	add.w	d0,d0
	move.w	st2_ops(pc,d0.w),d0
	jmp	st2_ops(pc,d0.w)
.bad:	move.w	#$ffff,d0
	bra	st2_timer

st2_ops:
	dc.w	op_kill-st2_ops, op_vanish-st2_ops, op_flag1-st2_ops, op_flag0-st2_ops
	dc.w	op_loop-st2_ops, op_type-st2_ops, op_spdadd-st2_ops, op_spdsub-st2_ops
	dc.w	op_spdset-st2_ops, op_angadd-st2_ops, op_angsub-st2_ops, op_angset-st2_ops
	dc.w	op_angrnd-st2_ops, op_angspread-st2_ops, op_angspd-st2_ops, op_aimturn-st2_ops
	dc.w	op_aim-st2_ops, st2_after-st2_ops, st2_after-st2_ops, op_accadd-st2_ops

op_kill:				; $350
	subq.w	#1,SYS+$02(a5)
	subq.w	#1,SYS+$06(a5)
	clr.w	(a0)
	rts
op_vanish:
	bsr	vanish_3a4
	bra	st3
op_flag1:
	move.w	#1,O_FLAG(a0)
	bra	st2_after
op_flag0:
	clr.w	O_FLAG(a0)
	bra	st2_after
op_loop:
	move.w	O_CNT(a0),d0
	bne.s	.nz
	moveq	#0,d1
	move.b	(a1),d1			; ARM byte 1 of the instruction: repeat count
	move.w	d1,O_CNT(a0)
	beq	st2_after
	bra.s	.jump
.nz:	subq.w	#1,d0
	move.w	d0,O_CNT(a0)
	bne.s	.jump
	clr.w	O_WAIT(a0)
	bra	st2_advance
.jump:	moveq	#0,d1
	move.w	4(a1),d1
	lsl.l	#3,d1
	movea.l	O_SCRIPT(a0),a1
	suba.l	d1,a1
	move.l	a1,O_SCRIPT(a0)
	moveq	#0,d0
	move.b	(a1),d0
	move.w	d0,O_WAIT(a0)
	bra	st2_exec
op_type:
	moveq	#0,d1
	move.w	4(a1),d1
	lsl.l	#3,d1
	lea	T_TYPES,a2
	adda.l	d1,a2
	move.l	(a2)+,O_P1E(a0)
	move.l	(a2),O_OX(a0)
	move.w	O_P1E(a0),d1
	tst.b	O_DIRANIM(a0)
	beq.s	.nd
	moveq	#0,d0
	move.b	O_ANG(a0),d0
	addq.w	#4,d0
	andi.w	#$ff,d0
	lsr.w	#3,d0
	add.w	d0,d0
	add.w	d0,d0
	add.w	d0,d1
.nd:	move.w	d1,O_ABASE(a0)
	moveq	#0,d1
	move.b	O_NFRAMES(a0),d1
	move.w	d1,O_AFRAME(a0)
	clr.w	O_ACNT(a0)
	bra	st2_after
op_spdadd:
	move.w	4(a1),d1
	add.w	O_SPEED(a0),d1
	bra.s	op_spd
op_spdsub:
	move.w	O_SPEED(a0),d1
	sub.w	4(a1),d1
	bra.s	op_spd
op_spdset:
	move.w	4(a1),d1
op_spd:	move.w	d1,O_SPEED(a0)
	moveq	#0,d0
	move.b	O_ANG(a0),d0
	move.l	a1,-(sp)
	bsr	set_vel
	movea.l	(sp)+,a1
	bra	st2_after
op_angadd:
	moveq	#0,d0
	move.b	O_ANG(a0),d0
	add.w	4(a1),d0
	bra.s	op_ang
op_angsub:
	moveq	#0,d0
	move.b	O_ANG(a0),d0
	sub.w	4(a1),d0
	bra.s	op_ang
op_angset:
	move.w	4(a1),d0
op_ang:	andi.w	#$ff,d0
	move.b	d0,O_ANG(a0)
	move.w	O_SPEED(a0),d1
	move.l	a1,-(sp)
	move.w	d0,-(sp)
	bsr	set_vel
	move.w	(sp)+,d0
	bsr	dir_anim
	movea.l	(sp)+,a1
	bra	st2_after
op_angrnd:				; a1 + (rng & (a2-1))
	move.l	a1,-(sp)
	bsr	rng
	movea.l	(sp),a1
	move.w	6(a1),d1
	subq.w	#1,d1
	and.w	d1,d0
	add.w	4(a1),d0
	bra.s	op_ang_saved
op_angspread:				; ang -= a2/2 ; ang += rng & (a2-1)
	move.w	6(a1),d1
	lsr.w	#1,d1
	sub.b	d1,O_ANG(a0)
	move.l	a1,-(sp)
	bsr	rng
	movea.l	(sp),a1
	move.w	6(a1),d1
	subq.w	#1,d1
	and.w	d1,d0
	moveq	#0,d1
	move.b	O_ANG(a0),d1
	add.w	d1,d0
op_ang_saved:
	andi.w	#$ff,d0
	move.b	d0,O_ANG(a0)
	move.w	O_SPEED(a0),d1
	move.w	d0,-(sp)
	bsr	set_vel
	move.w	(sp)+,d0
	bsr	dir_anim
	movea.l	(sp)+,a1
	bra	st2_after
op_angspd:
	move.b	7(a1),O_ANG(a0)		; low byte of a2
	move.w	4(a1),O_SPEED(a0)
	moveq	#0,d0
	move.b	O_ANG(a0),d0
	bra	op_ang
op_aimturn:
	move.l	a1,-(sp)
	move.w	4(a1),d2
	bsr	aim			; d0 = target
	movea.l	(sp),a1
	moveq	#0,d1
	move.b	O_ANG(a0),d1		; current
	cmp.w	d1,d0
	beq.s	.same
	move.w	d0,d2
	sub.w	d1,d2			; target - current
	moveq	#0,d0
	move.b	7(a1),d0		; step = a2 & $ff
	cmpi.w	#$7f,d2
	ble.s	.pos
	neg.w	d0
.pos:	add.w	d1,d0
	bra.s	op_ang_saved
.same:	addq.l	#4,sp
	bra	st2_after
op_aim:
	move.l	a1,-(sp)
	move.w	4(a1),d2
	bsr	aim
	bra.s	op_ang_saved
op_accadd:
	move.w	4(a1),d0
	add.w	d0,O_AX(a0)
	move.w	6(a1),d0
	add.w	d0,O_AY(a0)
	; fall through

; instruction finished: repeat it (wait count) or step to the next one
st2_after:
	tst.w	O_WAIT(a0)
	beq.s	st2_advance
	subq.w	#1,O_WAIT(a0)
	movea.l	O_SCRIPT(a0),a1
	moveq	#0,d0
	move.b	1(a1),d0		; ARM byte 0: duration
	bra.s	st2_timer
st2_advance:
	movea.l	O_SCRIPT(a0),a1
	moveq	#0,d0
	move.b	8(a1),d0		; next instruction's repeat count (ARM byte 9)
	move.w	d0,O_WAIT(a0)
	addq.l	#8,a1
	move.l	a1,O_SCRIPT(a0)
	move.b	1(a1),d0		; its duration
st2_timer:
	move.w	d0,O_TIMER(a0)
	cmpi.w	#-9,d5
	ble.s	.off			; @unlikely
	cmpi.w	#$e8,d5
	bge.s	.off			; @unlikely
	cmpi.w	#-9,d4
	ble.s	.off			; @unlikely
	cmpi.w	#$1c7,d4
	bgt.s	.off			; @unlikely
.on:	SPRXY	d4,d5,O_OX(a0),O_OY(a0),d0
	move.w	d4,O_X(a0)
	move.w	d5,O_Y(a0)
	move.w	O_VX(a0),d0
	add.w	d0,O_AX(a0)
	move.w	O_VY(a0),d0
	add.w	d0,O_AY(a0)
	subq.w	#1,O_ACNT(a0)
	bcs.s	st2_frame		; @unlikely
	rts
.off:	tst.w	O_FLAG(a0)
	bne.s	.on
	bra	op_kill
st2_frame:
	move.w	O_APER(a0),O_ACNT(a0)
	move.w	O_AFRAME(a0),d0
	move.w	d0,d1
	subq.w	#1,d1
	bcc.s	.fs
	moveq	#0,d1
	move.b	O_NFRAMES(a0),d1
.fs:	move.w	d1,O_AFRAME(a0)
	; entry = T_1714 + 8*ABASE - 8*frame (32-bit)
	moveq	#0,d1
	move.w	O_ABASE(a0),d1
	andi.l	#$ffff,d0
	sub.l	d0,d1
	lsl.l	#3,d1
	lea	T_1714,a1
	adda.l	d1,a1
	move.w	(a1)+,d0
	andi.w	#$e0ff,d0
	ori.w	#$1700,d0
	move.w	d0,O_SPR(a0)
	move.w	(a1)+,O_SPR+2(a0)
	move.l	(a1),O_SPR+4(a0)
	rts

; ---------------------------------------------------------------------------
; state 3: vanish
; ---------------------------------------------------------------------------
st3:
	move.w	O_WAIT(a0),d3
	bne.s	.w
	subq.w	#1,SYS+$02(a5)		; $37C
	subq.w	#1,SYS+$08(a5)
	clr.w	(a0)
	rts
.w:	subq.w	#1,d3
	move.w	d3,O_WAIT(a0)
	move.w	O_AX(a0),d4
	SPLIT	d4,O_AX,d0,d1
	move.w	O_AY(a0),d5
	SPLIT	d5,O_AY,d0,d1
	add.w	O_X(a0),d4
	add.w	O_Y(a0),d5
	add.w	d7,d5
	lea	T_VANISH,a1		; ARM $08000134 - 8*wait
	moveq	#0,d1
	move.w	d3,d1
	lsl.l	#3,d1
	suba.l	d1,a1
	move.l	(a1)+,O_SPR(a0)
	move.l	(a1),O_SPR+4(a0)
	andi.w	#$e0ff,O_SPR(a0)
	ori.w	#$1700,O_SPR(a0)
	move.w	d4,d0
	andi.w	#$7ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRX(a0)
	move.w	d5,d0
	andi.w	#$3ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRY(a0)
	move.w	d4,O_X(a0)
	move.w	d5,O_Y(a0)
	move.w	O_VX(a0),d0
	add.w	d0,O_AX(a0)
	move.w	O_VY(a0),d0
	add.w	d0,O_AY(a0)
	rts

; ---------------------------------------------------------------------------
; state 1: appear
; ---------------------------------------------------------------------------
st1:
	move.w	O_TIMER(a0),d0
	beq	.go
	subq.w	#1,d0
	move.w	d0,O_TIMER(a0)
	tst.w	O_WAIT(a0)
	bne.s	.w1
	move.w	#1,O_WAIT(a0)
	bra.s	.w2
.w1:	add.w	d7,O_Y(a0)
.w2:	move.w	O_SUB(a0),d0
	bne.s	.sub
	lea	T_1718,a1
	move.l	(a1)+,O_SPRX(a0)
	move.l	(a1)+,O_SPRX+4(a0)
	move.l	(a1),O_SPRX+8(a0)
	rts
.sub:	moveq	#0,d1
	move.w	O_CNT(a0),d1
	cmpi.w	#2,d0
	bne.s	.dir
	addq.w	#1,O_CNT(a0)
	bra.s	.idx
.dir:	move.w	SYS+$16(a5),d2
	addq.w	#1,d2
	move.w	d2,SYS+$16(a5)
	lsl.l	#7,d1
	moveq	#0,d0
	move.b	O_ANG(a0),d0
	addq.w	#4,d0
	andi.w	#$ff,d0
	lsr.w	#3,d0
	add.w	d0,d0
	add.w	d0,d0
	add.l	d0,d1
	andi.l	#3,d2
	add.l	d2,d1
	andi.l	#$ffff,d1
.idx:	move.l	d1,d0
	lsl.l	#3,d0
	lea	T_1720,a1
	adda.l	d0,a1
	move.l	(a1)+,O_SPR(a0)
	move.l	(a1),O_SPR+4(a0)
	andi.w	#$e0ff,O_SPR(a0)
	ori.w	#$1700,O_SPR(a0)
	lsl.l	#2,d1
	lea	T_171C,a1
	adda.l	d1,a1
	move.w	O_X(a0),d0
	sub.w	(a1)+,d0
	andi.w	#$7ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRX(a0)
	move.w	O_Y(a0),d0
	sub.w	(a1),d0
	andi.w	#$3ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRY(a0)
	rts
.go:	tst.w	O_WAIT(a0)
	bne.s	.g1
	sub.w	d7,O_Y(a0)
.g1:	tst.w	SYS+$14(a5)
	beq.s	.g2
	bsr	vanish_40c
	bra	st3
.g2:	move.l	O_SCRIPT(a0),d0
	bne.s	.g3
	move.w	#$ffff,O_TIMER(a0)
	bra.s	.g4
.g3:	movea.l	d0,a1
	moveq	#0,d0
	move.b	(a1),d0			; ARM byte 1: repeat
	move.w	d0,O_WAIT(a0)
	move.b	1(a1),d0		; ARM byte 0: duration
	move.w	d0,O_TIMER(a0)
	clr.w	O_CNT(a0)
.g4:	clr.w	O_SUB(a0)
	move.w	#2,(a0)
	addq.w	#1,SYS+$06(a5)
	subq.w	#1,SYS+$04(a5)
	bra	st2

; ---------------------------------------------------------------------------
; state 4: bouncing debris
; ---------------------------------------------------------------------------
st4_vel:				; consume a bounce: a1 = T_172C entry
	subq.w	#1,O_TIMER(a0)
	move.w	SYS+S_CNT86(a5),d0
	addq.w	#1,d0
	move.w	d0,SYS+S_CNT86(a5)
	andi.w	#3,d0
	add.w	d0,d0
	add.w	d0,d0
	lea	T_172C,a1
	adda.w	d0,a1
	rts

st4:
	move.w	O_VX(a0),d2		; vx
	move.w	O_VY(a0),d3		; vy
	move.w	O_AX(a0),d4
	add.w	d2,d4
	SPLIT	d4,O_AX,d0,d1
	move.w	O_AY(a0),d5
	add.w	d3,d5
	SPLIT	d5,O_AY,d0,d1
	add.w	O_X(a0),d4
	move.w	d4,O_X(a0)		; x
	add.w	O_Y(a0),d5
	add.w	d7,d5
	move.w	d5,O_Y(a0)		; y
	tst.w	O_TIMER(a0)
	beq.s	.nob
	tst.w	d2
	bgt.s	.right
	cmpi.w	#$e,d4
	bgt.s	.vert
	bsr	st4_vel			; left edge
	move.w	(a1)+,O_VX(a0)
	move.w	(a1),d0
	neg.w	d0
	move.w	d0,O_VY(a0)
	bra.s	.draw
.right:	cmpi.w	#$1b2,d4
	blt.s	.vert
	bsr	st4_vel			; right edge
	move.w	(a1)+,d0
	neg.w	d0
	move.w	d0,O_VX(a0)
	move.w	(a1),O_VY(a0)
	bra.s	.draw
.vert:	tst.w	d3
	bgt.s	.down
	cmpi.w	#$d,d5
	bge.s	.draw
	bsr	st4_vel			; top edge
	move.l	(a1),O_VX(a0)
	bra.s	.draw
.down:	cmpi.w	#$d3,d5
	ble.s	.draw
	bsr	st4_vel			; bottom edge
	move.w	(a1)+,d0
	neg.w	d0
	move.w	d0,O_VX(a0)
	move.w	(a1),d0
	neg.w	d0
	move.w	d0,O_VY(a0)
	bra.s	.draw
.nob:	tst.w	d2			; no bounces left: die once off screen
	bgt.s	.nr
	cmpi.w	#-$e,d4
	ble.s	.die
	bra.s	.ny
.nr:	cmpi.w	#$1ce,d4
	bge.s	.die
.ny:	tst.w	d3
	bgt.s	.nd
	cmpi.w	#-$c,d5
	bgt.s	.draw
	bra.s	.die
.nd:	cmpi.w	#$ec,d5
	blt.s	.draw
.die:	subq.w	#1,SYS+$02(a5)		; $528
	subq.w	#1,SYS+$0a(a5)
	subq.w	#1,SYS+$0e(a5)
	clr.w	(a0)
	rts
.draw:	move.w	d4,d0
	subi.w	#$e,d0
	andi.w	#$7ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRX(a0)
	move.w	d5,d0
	subi.w	#$f,d0
	andi.w	#$3ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRY(a0)
	bra	anim_up

; ---------------------------------------------------------------------------
; state 5: falling debris
; ---------------------------------------------------------------------------
st5:
	move.w	O_AX(a0),d4
	add.w	O_VX(a0),d4
	SPLIT	d4,O_AX,d0,d1
	move.w	O_AY(a0),d5
	add.w	O_VY(a0),d5
	SPLIT	d5,O_AY,d0,d1
	add.w	O_X(a0),d4
	move.w	d4,O_X(a0)
	cmp.w	O_FLAG(a0),d4
	bgt.s	.alive
	subq.w	#1,SYS+$02(a5)		; $500
	subq.w	#1,SYS+$10(a5)
	clr.w	(a0)
	rts
.alive:	subi.w	#$10,O_VX(a0)
	add.w	O_Y(a0),d5
	add.w	d7,d5
	move.w	d5,O_Y(a0)
	SPRXY	d4,d5,O_OX(a0),O_OY(a0),d0
	bra	anim_down

; ---------------------------------------------------------------------------
; states 6 / 7: items moving with the background
; ---------------------------------------------------------------------------
item_move:
	tst.w	O_TIMER(a0)
	beq.s	.m
	clr.w	O_TIMER(a0)
	rts
.m:	move.w	GLOB+8(a5),d0
	cmpi.w	#2,O_P1E(a0)
	bne.s	.s
	move.w	GLOB+10(a5),d0
.s:	add.w	d0,O_X(a0)
	add.w	d7,O_Y(a0)
	rts

st6:
	bsr.s	item_move
	move.w	O_X(a0),d4
	cmpi.w	#-$e,d4
	ble.s	.die
	move.w	O_Y(a0),d5
	move.w	d4,d0
	subi.w	#$e,d0
	andi.w	#$7ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRX(a0)
	move.w	d5,d0
	subi.w	#$f,d0
	andi.w	#$3ff,d0
	ori.w	#$8000,d0
	move.w	d0,O_SPRY(a0)
	bra	anim_up
.die:	subq.w	#1,SYS+$02(a5)		; $4B4
	subq.w	#1,SYS+$0c(a5)
	subq.w	#1,SYS+$0a(a5)
	bsr	push_removed
	clr.w	(a0)
	rts

st7:
	bsr.s	item_move
	move.w	O_X(a0),d4
	cmp.w	O_FLAG(a0),d4
	bgt.s	.alive
	subq.w	#1,SYS+$02(a5)		; $474
	subq.w	#1,SYS+$0c(a5)
	bsr	push_removed
	clr.w	(a0)
	rts
.alive:	move.w	O_Y(a0),d5
	SPRXY	d4,d5,O_OX(a0),O_OY(a0),d0
	bra	anim_down
