; ---------------------------------------------------------------------------
; est_results: cmd 14 result packer (ARM $2340)
; in: a4 = SHWIN, a5 = HLEV
; Output (68k view of shared RAM):
;   $1500 + 16*i : object i words 0..4 (state, type, sub, x, y)
;   $0EC0        : sprite words 14..18 of objects in states 1..3, packed
;   $0880        : ... state 5          $07E0 : ... state 4 (+ $3000 list: type, x, y)
;   $05E0+10*id  : ... states 6/7 (and above) by item id
;   $1F00        : SYS words 0..11, $1F18/$1F1C removed item list
;
; The object loop accounts for itself (no per-block markers): every path through one
; iteration has a fixed cost, so the loop's total follows from how many objects took
; each path - the same counts the ARM's run time (the cmd 14 wait) depends on.
; Cycles per iteration without the dbra (SUM = 68, the copy of words 0..4; bullets in
; states 1-3, the common case, are tested first; HEAD = 8+8+8+10 for the others):
;   state 0           8 + 10 + SUM                        =  86
;   states 1-3        8+8+8+8 + 68 + SUM                  = 168
;   state 5           HEAD + 8+8 + 78 + SUM                         = 196
;   state 4           HEAD + 8+10 + 8+12+4+14+14 + 160 + SUM        = 332
;   states 6, 7       HEAD + 8+10 + 8+12+4+14+14 + 8 + 158 + SUM    = 338
;   above 7           HEAD + 8+10 + 8+10 + 26 + 158 + SUM           = 322  (the firmware's 6/7 path)
; plus the dbra (10 per pass, 14 at the end) and one bra.s (10) leaving the loop.
; ---------------------------------------------------------------------------
PK_DEAD		equ	86
PK_S123		equ	168
PK_S5		equ	196
PK_S4		equ	332
PK_S67		equ	338
PK_HIGH		equ	322

est_results:
	lea	POOL(a5),a0
	lea	$1500(a4),a1
	lea	$0EC0(a4),a2
	lea	$0880(a4),a6
	move.w	#$07E0,d4		; state 4 block offset in SHWIN
	move.w	#$3000,d7		; state 4 list offset in SHWIN
	moveq	#0,d2			; objects in state 4
	moveq	#0,d3			; ... states 1-3
	moveq	#0,d5			; ... state 5
	moveq	#0,d6			; ... states 6/7 (low word), above 7 (high word)
	moveq	#NOBJ-1,d1
	; @cyc-off
.obj:	move.w	(a0),d0			;  8
	beq.s	.sum			; 10 / 8
	cmpi.w	#3,d0			;  8
	bhi.s	.other			; 10 / 8
	addq.w	#1,d3			;  4
	move.l	O_SPRX(a0),(a2)+	; 24
	move.l	O_SPRX+4(a0),(a2)+	; 24
	move.w	O_SPRX+8(a0),(a2)+	; 16  = 68
.sum:	move.l	(a0)+,(a1)+		; 20
	move.l	(a0)+,(a1)+		; 20
	move.w	(a0),(a1)		; 12
	lea	OBJ_SIZE-8(a0),a0	;  8
	lea	8(a1),a1		;  8  = 68
	dbra	d1,.obj			; 10 / 14
	bra.w	.out			; 10 (as bra.s)
.other:	cmpi.w	#5,d0			;  8
	bne.s	.n5			; 10 / 8
	addq.w	#1,d5			;  4
	move.l	O_SPRX(a0),(a6)+	; 24
	move.l	O_SPRX+4(a0),(a6)+	; 24
	move.w	O_SPRX+8(a0),(a6)+	; 16
	bra.s	.sum			; 10  = 78
.n5:	cmpi.w	#7,d0			;  8
	bhi.w	.high			; 10 / 12
	add.w	d0,d0			;  4
	move.w	.tab-8(pc,d0.w),d0	; 14
	jmp	.tab(pc,d0.w)		; 14
.tab:	dc.w	.s4-.tab, 0, .s67-.tab, .s67-.tab
.s4:	addq.w	#1,d2			;  4
	move.l	O_SPRX(a0),0(a4,d4.w)	; 30
	move.l	O_SPRX+4(a0),4(a4,d4.w)	; 30
	move.w	O_SPRX+8(a0),8(a4,d4.w)	; 22
	addi.w	#10,d4			;  8
	move.w	O_TYPE(a0),0(a4,d7.w)	; 22
	move.l	O_X(a0),2(a4,d7.w)	; 30
	addq.w	#6,d7			;  4
	bra.s	.sum			; 10  = 160
.s67:	addq.w	#1,d6			;  4
	moveq	#0,d0			;  4  = 8
.item:	move.b	O_ITEM(a0),d0		; 12
	mulu.w	#10,d0			; 46
	addi.w	#$05E0,d0		;  8
	move.l	O_SPRX(a0),0(a4,d0.w)	; 30
	move.l	O_SPRX+4(a0),4(a4,d0.w)	; 30
	move.w	O_SPRX+8(a0),8(a4,d0.w)	; 22
	bra.w	.sum			; 10  = 158
.high:	swap	d6			;  4
	addq.w	#1,d6			;  4
	swap	d6			;  4
	moveq	#0,d0			;  4
	bra.s	.item			; 10  = 26
.out:
	; @cyc-on
	; loop cycles = NOBJ*PK_DEAD + (NOBJ-1)*10 + 14 + 10 + n(1-3)*(PK_S123-PK_DEAD)
	;             + n5*(PK_S5-PK_DEAD) + n4*(PK_S4-PK_DEAD) + n67*(PK_S67-PK_DEAD)
	;             + nhigh*(PK_HIGH-PK_DEAD)
	lea	NOBJ*PK_DEAD+(NOBJ-1)*10+14+10(a3),a3	; @cyc-adjust
	move.w	d3,d0
	mulu.w	#PK_S123-PK_DEAD,d0
	adda.l	d0,a3			; @cyc-adjust
	move.w	d5,d0
	mulu.w	#PK_S5-PK_DEAD,d0
	adda.l	d0,a3			; @cyc-adjust
	move.w	d2,d0
	mulu.w	#PK_S4-PK_DEAD,d0
	adda.l	d0,a3			; @cyc-adjust
	move.w	d6,d0
	mulu.w	#PK_S67-PK_DEAD,d0
	adda.l	d0,a3			; @cyc-adjust
	swap	d6
	move.w	d6,d0
	mulu.w	#PK_HIGH-PK_DEAD,d0
	adda.l	d0,a3			; @cyc-adjust

	; ARM time of this packer x10 (for the cmd 14 wait); objects above state 7 take
	; the firmware's 6/7 path
	moveq	#0,d0
	move.w	d6,d0			; nhigh (d6 is still swapped)
	swap	d6
	add.w	d6,d0			; + n67
	mulu.w	#C14_STATE67,d0
	move.l	d0,d1
	move.w	d3,d0
	mulu.w	#C14_STATE123,d0
	add.l	d0,d1
	move.w	d2,d0
	mulu.w	#C14_STATE4,d0
	add.l	d0,d1
	move.w	d5,d0
	mulu.w	#C14_STATE5,d0
	add.l	d0,d1
	addi.l	#C14_CONST,d1
	move.l	d1,d3

	lea	SYS(a5),a0		; header back to the 68k
	lea	$1F00(a4),a1
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.w	SYS+S_REMOVED_N(a5),d0
	beq.s	.norem
	mulu.w	#C14_REMOVED,d0
	add.l	d0,d3
	addi.l	#C14_REMOVED_FIRST,d3
.norem:
	; extra polls E = ceil((D - first poll) / poll period), all x10; E < 256.
	; Binary long division in 8 fixed steps (no DIVU: its timing is data dependent).
	subi.l	#FIRST_POLL_X10-(POLL_PERIOD_X10-1),d3
	moveq	#0,d1
DIVSTEP		macro
		cmpi.l	#(POLL_PERIOD_X10<<\1),d3
		bcs.s	.d\@
		subi.l	#(POLL_PERIOD_X10<<\1),d3
		addi.w	#(1<<\1),d1
.d\@:
		endm
	DIVSTEP	7
	DIVSTEP	6
	DIVSTEP	5
	DIVSTEP	4
	DIVSTEP	3
	DIVSTEP	2
	DIVSTEP	1
	DIVSTEP	0
	move.w	d1,E14(a5)
	move.w	SYS+S_REMOVED_N(a5),d0
	beq.s	.done
	move.w	d0,$1F18(a4)
	lea	SYS+S_REMOVED(a5),a0
	lea	$1F1C(a4),a1
	subq.w	#1,d0
.rm:	move.w	(a0)+,(a1)+
	dbra	d0,.rm
.done:	rts
