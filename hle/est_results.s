; ---------------------------------------------------------------------------
; est_results: cmd 14 result packer (ARM $2340)
; in: a4 = SHWIN, a5 = HLEV
; Output (68k view of shared RAM):
;   $1500 + 16*i : object i words 0..4 (state, type, sub, x, y)
;   $0EC0        : sprite words 14..18 of objects in states 1..3, packed
;   $0880        : ... state 5          $07E0 : ... state 4 (+ $3000 list: type, x, y)
;   $05E0+10*id  : ... states 6/7 by item id
;   $1F00        : SYS words 0..11, $1F18/$1F1C removed item list
; ---------------------------------------------------------------------------
est_results:
	lea	POOL(a5),a0
	lea	$1500(a4),a1
	lea	$0EC0(a4),a2
	lea	$0880(a4),a3
	move.w	#$07E0,d5		; state 4 block offset in SHWIN
	move.w	#$3000,d6		; state 4 list offset in SHWIN
	moveq	#NOBJ-1,d7
.obj:	move.w	(a0),d0
	beq.s	.sum
	cmpi.w	#4,d0
	bcs.s	.s123
	beq.s	.s4
	cmpi.w	#5,d0
	beq.s	.s5
	; states 6/7 (and anything above): slot chosen by item id
	moveq	#0,d1
	move.b	O_ITEM(a0),d1
	mulu.w	#10,d1
	lea	$05E0(a4),a6
	adda.l	d1,a6
	move.l	O_SPRX(a0),(a6)+
	move.l	O_SPRX+4(a0),(a6)+
	move.w	O_SPRX+8(a0),(a6)
	bra.s	.sum
.s123:	move.l	O_SPRX(a0),(a2)+
	move.l	O_SPRX+4(a0),(a2)+
	move.w	O_SPRX+8(a0),(a2)+
	bra.s	.sum
.s5:	move.l	O_SPRX(a0),(a3)+
	move.l	O_SPRX+4(a0),(a3)+
	move.w	O_SPRX+8(a0),(a3)+
	bra.s	.sum
.s4:	lea	(a4,d5.w),a6
	move.l	O_SPRX(a0),(a6)+
	move.l	O_SPRX+4(a0),(a6)+
	move.w	O_SPRX+8(a0),(a6)
	addi.w	#10,d5
	move.w	O_TYPE(a0),(a4,d6.w)
	move.l	O_X(a0),2(a4,d6.w)
	addq.w	#6,d6
.sum:	move.l	(a0),(a1)+
	move.l	4(a0),(a1)+
	move.w	8(a0),(a1)
	addq.l	#8,a1
	lea	OBJ_SIZE(a0),a0
	dbra	d7,.obj

	lea	SYS(a5),a0		; header back to the 68k
	lea	$1F00(a4),a1
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.w	SYS+S_REMOVED_N(a5),d0
	beq.s	.done
	move.w	d0,$1F18(a4)
	lea	SYS+S_REMOVED(a5),a0
	lea	$1F1C(a4),a1
	subq.w	#1,d0
.rm:	move.w	(a0)+,(a1)+
	dbra	d0,.rm
.done:	rts
