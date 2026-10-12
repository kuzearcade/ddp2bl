;---------------------------------------------------------------------------
; job.s: everything that runs inside the EST job (from hle_run_job), i.e. the code
; whose exact cycle count is accounted at run time. tools/cycacc.py turns this file
; (and its includes) into build/job_acc.s by inserting, at every basic block,
;     lea <cycles of the block>(a3),a3      (LEA leaves the condition codes alone)
; so that a3 holds the exact 68000 cycle count of the path taken. Rules for this code:
;   * a3 is reserved (never used otherwise);
;   * no instruction with data-dependent timing except MULS/MULU on an immediate, or
;     on a sine table entry with the explicit MULCOST correction (see set_vxy);
;   * every branch target is a label (no computed branches except PC-relative tables).
;---------------------------------------------------------------------------

; run the pending job (cmd 12: update, cmd 13: animate) and pack the results
hle_run_job:
	lea	HLEV,a5
	lea	SHWIN,a4
	move.w	PENDING(a5),d0
	clr.w	PENDING(a5)
	cmpi.b	#$13,d0			; $13, or $113 once cmd 14 has answered "busy"
	beq.s	.anim
	bsr	cmd_12
	bra	est_results
.anim:	bsr	cmd_13
	bra	est_results

; cmd 11: EST reset
cmd_11:	lea	POOL(a5),a0
	moveq	#NOBJ-1,d0
.k:	clr.w	(a0)
	lea	OBJ_SIZE(a0),a0
	dbra	d0,.k
	lea	SYS(a5),a0
	moveq	#$90/4-1,d0
.c:	clr.l	(a0)+
	dbra	d0,.c
	lea	POOL(a5),a0
	move.l	a0,S_SEARCH(a5)
	rts

; cmd 12 / 13 job bodies (run from hle_run_job, i.e. in the game's idle loop)
cmd_12:	bsr.s	est_start
	move.w	SYS+S_COUNT(a5),SYS+S_LATCHED(a5)
	bsr	est_requests
	bra	est_update

cmd_13:	bsr.s	est_start
	bsr	est_requests
	bra	est_animate

est_start:
	lea	$1F00(a4),a0		; header (24 bytes) -> SYS[0..$17]
	lea	SYS(a5),a1
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	move.l	(a0)+,(a1)+
	clr.w	SYS+S_REMOVED_N(a5)
	rts

;---------------------------------------------------------------------------
; irq_saved: how many polls the original saved because of the interrupt found during
; a send() wait (hle_send, send_irq). k = the original's first latch read after it:
;   stacked PC before T_1 (prologue) or at a pass-1 handler's first instruction (an
;   entry of SEND_TAB): k = 1; elsewhere in a pass-1 handler: k = 2; in send_wait or
;   send_wait_pv, pass j = E - (saved loop counter): k = j at the pass's first
;   instruction, else j + 1; in the last pass: none.
; HLEV+IRQ_S = max(0, min(E + 1 - k, skip)); skip = IRQ4_SKIP, or any for the vblank
; handler (its first return address is IRQ6_RET).
;---------------------------------------------------------------------------
irq_saved:
	movem.l	d0-d2/a0,-(sp)
	moveq	#0,d2
	move.w	HLEV+IRQ_PC,d2
	cmpi.w	#(SEND_P1&$ffff),d2
	bcs.s	.k1
	cmpi.w	#(SEND_WAITS&$ffff),d2
	bcs.s	.p1
	cmpi.w	#(SEND_LAST&$ffff),d2
	bcc.s	.none
	move.w	HLEV+IRQ_E,d1
	sub.w	HLEV+IRQ_D2,d1		; j
	cmpi.w	#(send_wait&$ffff),d2
	beq.s	.calc
	cmpi.w	#(send_wait_pv&$ffff),d2
	beq.s	.calc
	addq.w	#1,d1
	bra.s	.calc
.p1:	lea	SEND_TAB,a0		; a handler's entry: just before read 1
	moveq	#SEND_TABN-1,d1
.t:	move.w	(a0)+,d0
	addi.w	#(SEND_TAB&$ffff),d0
	cmp.w	d0,d2
	beq.s	.k1
	dbra	d1,.t
	moveq	#2,d1
	bra.s	.calc
.k1:	moveq	#1,d1
.calc:	move.w	HLEV+IRQ_E,d2
	addq.w	#1,d2
	sub.w	d1,d2			; E + 1 - k
	ble.s	.none
	moveq	#IRQ4_SKIP,d1
	cmpi.l	#IRQ6_RET,HLEV+IRQ_RET
	bne.s	.sk
	moveq	#127,d1
.sk:	cmp.w	d1,d2
	bls.s	.st
	move.w	d1,d2
.st:	move.w	d2,HLEV+IRQ_S
	movem.l	(sp)+,d0-d2/a0
	rts
.none:	clr.w	HLEV+IRQ_S
	movem.l	(sp)+,d0-d2/a0
	rts

	include	"est_results.s"
	include	"est_spawn.s"
	include	"est_engine.s"
