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

	include	"est_results.s"
	include	"est_spawn.s"
	include	"est_engine.s"
