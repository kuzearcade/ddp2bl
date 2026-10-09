; ---------------------------------------------------------------------------
; EST request processing (ARM $2280) and spawn/control handlers ($3C90 table)
; Register use while processing: a4 = SHWIN, a5 = HLEV, a2 = request (12 words),
; d7 = remaining count. Handlers may use d0-d6, a0, a1, a3, a6.
; ---------------------------------------------------------------------------

; request word n is at 2n(a2)

est_requests:
	lea	$1F80(a4),a2
	move.w	SYS+S_COUNT(a5),d7
	subq.w	#1,d7
	bcs.s	.done
.loop:	move.w	(a2),d0
	cmpi.w	#14,d0
	bhi.s	.next			; firmware asserts (hang); never happens
	add.w	d0,d0
	move.w	.tab(pc,d0.w),d0
	jsr	.tab(pc,d0.w)
.next:	lea	24(a2),a2
	dbra	d7,.loop
.done:	clr.w	SYS+S_COUNT(a5)
	rts
.tab:	dc.w	sp_bullet-.tab, sp_kill-.tab, sp_vanish-.tab, sp_setsub-.tab
	dc.w	sp_clearlow-.tab, sp_vanishall-.tab, sp_vanishtype-.tab, sp_todebris-.tab
	dc.w	sp_multidebris-.tab, sp_debris-.tab, sp_falling-.tab, sp_item6-.tab
	dc.w	sp_item7-.tab, sp_removeitem-.tab, sp_stopbounce-.tab

; ---------------------------------------------------------------------------
; helpers
; ---------------------------------------------------------------------------

; find_free: a0 = first free slot at or after the search pointer (wrapping)
find_free:
	movea.l	SYS+S_SEARCH(a5),a0
	lea	POOL+(NOBJ-1)*OBJ_SIZE(a5),a1
.l:	cmpa.l	a1,a0
	bls.s	.c
	lea	POOL(a5),a0
.c:	tst.w	(a0)
	beq.s	.f
	lea	OBJ_SIZE(a0),a0
	bra.s	.l
.f:	rts

; slot_by_index: a0 = POOL + d0.w * $44
slot_by_index:
	mulu.w	#OBJ_SIZE,d0
	lea	POOL(a5),a0
	adda.l	d0,a0
	rts

; set_vel: angle d0.w (0..255), speed d1.w (unsigned) -> O_VX/O_VY of a0
; set_acc: same, writing O_AX/O_AY. Only d2, d3 and a6 are clobbered.
; v = (sin * speed) rounded toward zero >> 8 (s16 x u16 product, as the ARM)
set_acc:
	lea	O_AX(a0),a6
	bra.s	set_vxy
set_vel:
	lea	O_VX(a0),a6
set_vxy:
	move.l	a6,-(sp)		; destination
	lea	SINTAB,a6
	move.w	d0,d2
	add.w	d2,d2
	add.w	d2,d2
	adda.w	d2,a6
	move.w	2(a6),d3		; b
	move.w	(a6),d2			; a
	movea.l	(sp)+,a6
	tst.w	d1
	bmi.s	.big
	muls.w	d1,d2
	bpl.s	.p1
	addi.l	#$ff,d2
.p1:	asr.l	#8,d2
	move.w	d2,(a6)+
	muls.w	d1,d3
	bpl.s	.p2
	addi.l	#$ff,d3
.p2:	asr.l	#8,d3
	move.w	d3,(a6)
	rts
.big:	; speed >= $8000: muls sees speed-$10000, so add the missing factor<<16
	move.w	d2,-(sp)
	move.w	d3,-(sp)
	muls.w	d1,d2
	swap	d2
	add.w	2(sp),d2
	swap	d2
	tst.l	d2
	bpl.s	.b1
	addi.l	#$ff,d2
.b1:	asr.l	#8,d2
	move.w	d2,(a6)+
	muls.w	d1,d3
	swap	d3
	add.w	(sp),d3
	swap	d3
	tst.l	d3
	bpl.s	.b2
	addi.l	#$ff,d3
.b2:	asr.l	#8,d3
	move.w	d3,(a6)
	addq.l	#4,sp
	rts

; halve_vanish: object a0 -> state 3 (vanish), wait 6, x-5, y-8, v /= 2 (toward 0)
halve_vanish:
	move.w	#3,(a0)
	move.w	#6,O_WAIT(a0)
	subq.w	#5,O_X(a0)
	subq.w	#8,O_Y(a0)
	move.w	O_VX(a0),d0
	bpl.s	.a
	addq.w	#1,d0
.a:	asr.w	#1,d0
	move.w	d0,O_VX(a0)
	move.w	O_VY(a0),d0
	bpl.s	.b
	addq.w	#1,d0
.b:	asr.w	#1,d0
	move.w	d0,O_VY(a0)
	rts

; vanish_3a4 / vanish_40c: category counters + halve_vanish
vanish_3a4:
	subq.w	#1,SYS+$06(a5)
	addq.w	#1,SYS+$08(a5)
	bra.s	halve_vanish
vanish_40c:
	subq.w	#1,SYS+$04(a5)
	addq.w	#1,SYS+$08(a5)
	bra.s	halve_vanish

; push_removed: append item id of a0 to the removed list
push_removed:
	move.w	SYS+S_REMOVED_N(a5),d0
	addq.w	#1,SYS+S_REMOVED_N(a5)
	add.w	d0,d0
	moveq	#0,d1
	move.b	O_ITEM(a0),d1
	move.w	d1,SYS+S_REMOVED(a5,d0.w)
	rts

; anim_entry: a1 = T_ANIM + O_ABASE*8 + d0.w*8 ; copy 4 sprite words, set |$1800
copy_anim_1800:
	; a1 = T_ANIM + 8*O_ABASE + 8*frame(d0.w), 32-bit arithmetic like the ARM
	moveq	#0,d1
	move.w	O_ABASE(a0),d1
	lsl.l	#3,d1
	lea	T_ANIM,a1
	adda.l	d1,a1
	moveq	#0,d1
	move.w	d0,d1
	lsl.l	#3,d1
	adda.l	d1,a1
	move.l	(a1)+,O_SPR(a0)
	move.l	(a1),O_SPR+4(a0)
	andi.w	#$e0ff,O_SPR(a0)
	ori.w	#$1800,O_SPR(a0)
	rts

; ---------------------------------------------------------------------------
; id 0: scripted bullet (ARM $2064)
; ---------------------------------------------------------------------------
sp_bullet:
	bsr	find_free
	move.w	#1,(a0)
	moveq	#0,d0
	move.b	9(a2),d0		; angle = low byte of request word 4
	move.b	d0,O_ANG(a0)
	move.w	10(a2),d1		; speed
	move.w	d1,O_SPEED(a0)
	clr.w	O_WAIT(a0)
	move.w	2(a2),d2		; type
	move.w	d2,O_TYPE(a0)
	move.w	16(a2),O_SUB(a0)
	move.w	18(a2),O_CNT(a0)
	lea	T_TYPES,a1
	lsl.w	#3,d2
	move.l	(a1,d2.w),O_P1E(a0)
	move.l	4(a1,d2.w),O_OX(a0)
	move.w	O_P1E(a0),d3
	tst.b	O_DIRANIM(a0)
	beq.s	.nd
	move.w	d0,d4
	addq.w	#4,d4
	andi.w	#$ff,d4
	lsr.w	#3,d4
	add.w	d4,d4
	add.w	d4,d4
	add.w	d4,d3
.nd:	move.w	d3,O_ABASE(a0)
	clr.w	O_FLAG(a0)
	move.w	22(a2),d3
	add.w	d3,d3
	add.w	d3,d3
	lea	CTRLPTR,a1
	move.l	(a1,d3.w),O_SCRIPT(a0)
	moveq	#0,d3
	move.b	O_NFRAMES(a0),d3
	move.w	d3,O_AFRAME(a0)
	move.w	20(a2),O_TIMER(a0)
	move.w	14(a2),O_APER(a0)
	clr.w	O_ACNT(a0)
	move.w	4(a2),O_X(a0)
	move.w	6(a2),O_Y(a0)
	bsr	set_vel			; d0 = angle, d1 = speed
	move.w	12(a2),d1
	bsr	set_acc
	lea	OBJ_SIZE(a0),a1
	move.l	a1,SYS+S_SEARCH(a5)
	rts

; id 1: free slot REQ1 ($1F8C)
sp_kill:
	move.w	2(a2),d0
	bsr	slot_by_index
	clr.w	(a0)
	rts

; id 2: vanish slot REQ1 ($1FA8)
sp_vanish:
	move.w	2(a2),d0
	bsr	slot_by_index
	bra	halve_vanish

; id 3: set sub type of slot REQ1 to REQ6 ($2004)
sp_setsub:
	move.w	2(a2),d0
	bsr	slot_by_index
	move.w	12(a2),O_SUB(a0)
	rts

; id 4: free every object in states 0..2 ($1D54)
sp_clearlow:
	lea	POOL(a5),a0
	moveq	#NOBJ-1,d1
.l:	cmpi.w	#3,(a0)
	bcc.s	.n
	clr.w	(a0)
.n:	lea	OBJ_SIZE(a0),a0
	dbra	d1,.l
	rts

; id 5: vanish every scripted bullet ($1D80)
sp_vanishall:
	lea	POOL(a5),a0
	moveq	#NOBJ-1,d5
.l:	cmpi.w	#2,(a0)
	bne.s	.n
	bsr	halve_vanish
.n:	lea	OBJ_SIZE(a0),a0
	dbra	d5,.l
	rts

; id 6: vanish scripted bullets of type REQ1 ($1DF0)
sp_vanishtype:
	move.w	2(a2),d6
	lea	POOL(a5),a0
	moveq	#NOBJ-1,d5
.l:	cmpi.w	#2,(a0)
	bne.s	.n
	cmp.w	O_TYPE(a0),d6
	bne.s	.n
	bsr	vanish_3a4
.n:	lea	OBJ_SIZE(a0),a0
	dbra	d5,.l
	rts

; id 7: every scripted bullet becomes falling debris, appearing ones vanish ($1E34)
sp_todebris:
	move.w	2(a2),d6		; type
	moveq	#0,d2
	move.w	d6,d2
	lsl.w	#2,d2
	lea	T_19C4,a1
	move.l	(a1,d2.w),d4		; ox:oy
	moveq	#0,d3
	move.w	d6,d3
	add.w	d3,d3
	lea	T_19C8,a1
	move.w	(a1,d3.w),a3		; limit (kept in a3 as a word)
	move.w	d6,d2
	lsl.w	#5,d2
	addi.w	#$24,d2			; animation base
	move.w	SYS+S_CNT84(a5),d3
	andi.w	#$f,d3			; current frame
	lea	POOL(a5),a0
	moveq	#NOBJ-1,d5
.l:	move.w	(a0),d0
	cmpi.w	#2,d0
	beq.s	.conv
	cmpi.w	#1,d0
	bne.s	.n
	clr.w	(a0)
	bra.s	.n
.conv:	move.w	#5,(a0)
	move.w	d6,O_TYPE(a0)
	move.w	d3,O_AFRAME(a0)
	move.w	d2,O_ABASE(a0)
	move.w	SYS+S_CNT82(a5),d1
	addq.w	#1,d1
	move.w	d1,SYS+S_CNT82(a5)
	andi.w	#3,d1
	bne.s	.anim
	move.w	SYS+S_CNT84(a5),d3
	addq.w	#1,d3
	move.w	d3,SYS+S_CNT84(a5)
	andi.w	#$f,d3
	bra.s	.set
.anim:	movem.l	d1/d2,-(sp)
	move.w	d3,d0
	bsr	copy_anim_1800		; uses O_ABASE (= d2) + frame d0
	movem.l	(sp)+,d1/d2
.set:	move.w	d1,O_ACNT(a0)
	move.w	d1,d0
	lsl.w	#6,d0
	subi.w	#$40,d0
	move.w	d0,O_VX(a0)
	move.w	O_VY(a0),d0
	andi.w	#$f,d0
	subq.w	#7,d0
	move.w	d0,O_VY(a0)
	clr.l	O_AX(a0)		; AX and AY
	move.l	d4,O_OX(a0)
	move.w	a3,O_FLAG(a0)
.n:	lea	OBJ_SIZE(a0),a0
	dbra	d5,.l
	rts

; debris4_init: a0 = slot, d6 = type, d4 = x:y, d2 = animation base
debris4_init:
	move.w	#4,(a0)
	move.w	d6,O_TYPE(a0)
	move.w	SYS+S_CNT86(a5),d0
	addq.w	#1,d0
	move.w	d0,SYS+S_CNT86(a5)
	move.w	d0,d1
	andi.w	#3,d0
	add.w	d0,d0
	add.w	d0,d0
	lea	T_172C,a1
	move.w	(a1,d0.w),O_VX(a0)
	move.w	2(a1,d0.w),d0
	btst	#0,d1
	beq.s	.e
	neg.w	d0
.e:	move.w	d0,O_VY(a0)
	move.l	d4,O_X(a0)
	clr.l	O_AX(a0)
	move.w	#8,O_TIMER(a0)
	clr.w	O_AFRAME(a0)
	move.w	d2,O_ABASE(a0)
	clr.w	O_ACNT(a0)
	rts

; id 8: REQ6 bouncing debris pieces ($1BB0)
sp_multidebris:
	move.w	2(a2),d6
	move.l	4(a2),d4		; x:y
	move.w	d6,d2
	add.w	d2,d2
	add.w	d2,d2
	subi.w	#$10,d2
	movea.l	SYS+S_SEARCH(a5),a0
	lea	POOL+(NOBJ-1)*OBJ_SIZE(a5),a3
	move.w	12(a2),d5
	beq.s	.done
	subq.w	#1,d5
.each:	cmpa.l	a3,a0
	bls.s	.c
	lea	POOL(a5),a0
.c:	tst.w	(a0)
	beq.s	.f
	lea	OBJ_SIZE(a0),a0
	bra.s	.each
.f:	bsr	debris4_init
	lea	OBJ_SIZE(a0),a0
	dbra	d5,.each
.done:	move.l	a0,SYS+S_SEARCH(a5)
	rts

; id 9: one bouncing debris piece ($1AE8)
sp_debris:
	bsr	find_free
	move.w	2(a2),d6
	move.l	4(a2),d4
	move.w	d6,d2
	subq.w	#4,d2
	add.w	d2,d2
	add.w	d2,d2
	bsr	debris4_init
	lea	OBJ_SIZE(a0),a1
	move.l	a1,SYS+S_SEARCH(a5)
	rts

; id 10: falling debris ($189C)
sp_falling:
	bsr	find_free
	move.w	#5,(a0)
	move.w	2(a2),d6
	move.w	d6,O_TYPE(a0)
	move.w	SYS+S_CNT84(a5),d3
	andi.w	#$f,d3
	move.w	d3,O_AFRAME(a0)
	move.w	d6,d2
	lsl.w	#5,d2
	addi.w	#$24,d2
	move.w	d2,O_ABASE(a0)
	move.w	SYS+S_CNT82(a5),d1
	addq.w	#1,d1
	move.w	d1,SYS+S_CNT82(a5)
	andi.w	#3,d1
	bne.s	.anim
	addq.w	#1,SYS+S_CNT84(a5)
	bra.s	.set
.anim:	move.w	d3,d0
	move.w	d1,-(sp)
	bsr	copy_anim_1800
	move.w	(sp)+,d1
.set:	move.l	4(a2),O_X(a0)
	move.w	d1,d0
	lsl.w	#6,d0
	subi.w	#$40,d0
	move.w	d0,O_VX(a0)
	move.w	O_VY(a0),d0
	andi.w	#$3f,d0
	subi.w	#$1f,d0
	move.w	d0,O_VY(a0)
	clr.l	O_AX(a0)
	move.w	d6,d0
	add.w	d0,d0
	add.w	d0,d0
	lea	T_19C4,a1
	move.l	(a1,d0.w),O_OX(a0)
	move.w	d1,O_ACNT(a0)
	move.w	d6,d0
	add.w	d0,d0
	lea	T_19C8,a1
	move.w	(a1,d0.w),O_FLAG(a0)
	lea	OBJ_SIZE(a0),a1
	move.l	a1,SYS+S_SEARCH(a5)
	rts

; id 11: item, state 6 ($1C94)
sp_item6:
	bsr	find_free
	move.w	#6,(a0)
	move.w	2(a2),d0
	move.w	d0,O_TYPE(a0)
	move.b	9(a2),O_ITEM(a0)
	move.l	4(a2),O_X(a0)
	move.w	10(a2),O_P1E(a0)
	clr.w	O_AFRAME(a0)
	subq.w	#4,d0
	add.w	d0,d0
	add.w	d0,d0
	move.w	d0,O_ABASE(a0)
	clr.w	O_ACNT(a0)
	move.w	#1,O_TIMER(a0)
	lea	OBJ_SIZE(a0),a1
	move.l	a1,SYS+S_SEARCH(a5)
	rts

; id 12: item, state 7 ($19CC)
sp_item7:
	bsr	find_free
	move.w	#7,(a0)
	move.w	2(a2),d6
	move.w	d6,O_TYPE(a0)
	move.b	9(a2),O_ITEM(a0)
	move.w	10(a2),O_P1E(a0)
	move.w	SYS+S_CNT84(a5),d3
	addq.w	#1,d3
	move.w	d3,SYS+S_CNT84(a5)
	andi.w	#$f,d3
	move.w	d3,O_AFRAME(a0)
	move.w	d6,d2
	lsl.w	#5,d2
	addi.w	#$34,d2
	move.w	d2,O_ABASE(a0)
	move.w	SYS+S_CNT82(a5),d1
	addq.w	#1,d1
	move.w	d1,SYS+S_CNT82(a5)
	andi.w	#3,d1
	move.w	d1,O_ACNT(a0)
	beq.s	.na
	move.w	d3,d0
	bsr	copy_anim_1800
.na:	move.l	4(a2),O_X(a0)
	move.w	d6,d0
	add.w	d0,d0
	add.w	d0,d0
	lea	T_1AE0,a1
	move.l	(a1,d0.w),O_OX(a0)
	move.w	d6,d0
	add.w	d0,d0
	lea	T_1AE4,a1
	move.w	(a1,d0.w),O_FLAG(a0)
	move.w	#1,O_TIMER(a0)
	lea	OBJ_SIZE(a0),a1
	move.l	a1,SYS+S_SEARCH(a5)
	rts

; id 13: remove slot REQ1, logging items ($2020)
sp_removeitem:
	move.w	2(a2),d0
	bsr	slot_by_index
	cmpi.w	#5,(a0)
	bls.s	.k
	bsr	push_removed
.k:	clr.w	(a0)
	rts

; id 14: debris stops bouncing ($1D28)
sp_stopbounce:
	lea	POOL(a5),a0
	moveq	#NOBJ-1,d1
.l:	cmpi.w	#4,(a0)
	bne.s	.n
	clr.w	O_TIMER(a0)
.n:	lea	OBJ_SIZE(a0),a0
	dbra	d1,.l
	rts
