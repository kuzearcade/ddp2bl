; ---------------------------------------------------------------------------
; ddp2bl: 68000 replacement for the IGS027A protection (DoDonPachi II)
;
; Specification: oracle/est_model*.c (verified byte-exact against the ARM firmware).
; Assembled with vasmm68k_mot; addresses come from the generated target.inc.
;
; Data layout (68000 view)
;   SHWIN  : relocated ARM shared RAM. 68k word at SHWIN+n == ARM halfword at
;            $48000000+n, exactly what the 68k used to see at $D00000+n.
;   HLEV   : private state mirroring the ARM work RAM layout, stored as
;            big-endian halfwords. An ARM byte at offset b lives at b^1.
;            Pointers held by the ARM (script pointer, search pointer) are
;            kept as 68k addresses.
;   ROM tables (built by the tool from the user's ROMs, halfword-swapped to
;   big endian): EXTROM (external ROM data), SINTAB, AIMTAB (bytes, unswapped),
;   CTRLPTR (script pointers translated to 68k addresses).
; ---------------------------------------------------------------------------

	include	"target.inc"

; --- HLEV layout -----------------------------------------------------------
SYS		equ	$0000		; EST system variables (ARM $18000000, $90 bytes)
POOL		equ	$0090		; 128 objects x $44 (ARM $18000090..$1800228F)
OBJ_SIZE	equ	$44
NOBJ		equ	128
GLOB		equ	$2290		; cmd 09/0A parameters (ARM $18002FA4, 16 bytes)
RNG_M1		equ	$22A0		; RNG state[-1] (aliases an ARM message-queue word)
RNG_S		equ	$22A4		; 55 longs
RNG_K		equ	$2380		; long
RNG_J		equ	$2384		; long
LATCH		equ	$2388		; byte: value the 68k reads at its old latch address
PENDING		equ	$238A		; word: job accepted by cmd 12/13, not yet run
E14		equ	$238C		; word: extra polls cmd 14 takes (from the packer)
REQN		equ	$238E		; word: requests left (job)
HLEV_SIZE	equ	$2390

; --- SYS fields (ARM offsets, halfwords) -----------------------------------
S_COUNT		equ	$00		; request count / header [0..$17] round-trips via $1F00
S_TOTAL		equ	$02
S_REMOVED_N	equ	$18
S_LATCHED	equ	$1A
S_REMOVED	equ	$1C		; list of removed item ids
S_BUSY		equ	$80
S_CNT82		equ	$82
S_CNT84		equ	$84
S_CNT86		equ	$86
S_SEARCH	equ	$88		; long, 68k pointer
S_CONT		equ	$8C		; word: 0 = update ($55C), 1 = animate ($1730)

; --- object fields (ARM byte offsets) ---------------------------------------
O_STATE		equ	$00
O_TYPE		equ	$02
O_SUB		equ	$04
O_X		equ	$06
O_Y		equ	$08
O_VX		equ	$10
O_VY		equ	$12
O_AX		equ	$14
O_AY		equ	$16
O_ANG		equ	$18^1		; ARM byte $18 (low byte of halfword 12)
O_ITEM		equ	$19^1		; ARM byte $19
O_SPEED		equ	$1A
O_SPRX		equ	$1C
O_SPRY		equ	$1E
O_SPR		equ	$20		; 4 words
O_WAIT		equ	$28
O_CNT		equ	$2A
O_ABASE		equ	$2C
O_FLAG		equ	$2E
O_AFRAME	equ	$30
O_TIMER		equ	$32
O_APER		equ	$34
O_ACNT		equ	$36
O_SCRIPT	equ	$38		; long, 68k pointer
O_P1E		equ	$3C
O_DIRANIM	equ	$3E^1		; ARM byte $3E
O_NFRAMES	equ	$3F^1		; ARM byte $3F
O_OX		equ	$40
O_OY		equ	$42


; ===========================================================================
	org	HLE_BASE

; ---------------------------------------------------------------------------
; hle_send
; Entered by "jmp" from the game's send(cmd) in place of
;     its command-word store and latch post      (the send hook)
; with d2.l = command. In the reference (protected set, per-cycle interleave)
; the ARM replies D cycles after the latch write; the 68k polls first after
; FIRST_POLL cycles and then every 94, so it reaches SEND_EXIT after
;     266 + E*94 cycles,   E = extra polls = ceil((D - 146) / 94)
; (docs/timing.md; D per command from the calibrated model in target.json).
; We do the command and leave exactly the RAM/register effects of that path:
; seq var += 1 (& $7F), echo var = new seq, status var = 0, poll counter =
; $2710 - (E+1), d0.b = new seq (upper d0 unchanged), X = 0; d2 is free.
; Cheap commands are padded to exactly that many cycles. The variable waits
; (12/13/14) use a 94-cycle loop which, like the original poll loop, ends early
; when the vblank interrupt (IRQ6) fires during the wait.
; Cycle counts per instruction are in the comments (MC68000 manual tables).
; ---------------------------------------------------------------------------
hle_send:				; 12 (the jmp that got us here)
	move.l	d1,-(sp)		; 12
	move.b	SEQVAR,d0		; 16
	addq.b	#1,d0			;  4  (X = 0: seq <= $80)
	andi.b	#$7f,d0			;  8
	move.b	d0,SEQVAR		; 16
	clr.w	STATUSVAR		; 20
	move.b	d0,ECHOVAR		; 16
	move.b	d0,HLEV+LATCH		; 16  (read only by the game's error helper)
	move.l	VBLCNT,d1		; 20  vblank counter at the start of the wait
	add.w	d2,d2			;  4
	move.w	.tab(pc,d2.w),d2	; 14
	jmp	.tab(pc,d2.w)		; 14  = 172
.tab:	dc.w	snd_none-.tab, snd_01-.tab, snd_02-.tab, snd_03-.tab
	dc.w	snd_04-.tab, snd_none-.tab, snd_none-.tab, snd_none-.tab
	dc.w	snd_none-.tab, snd_09-.tab, snd_0a-.tab, snd_none-.tab
	dc.w	snd_none-.tab, snd_none-.tab, snd_none-.tab, snd_none-.tab
	dc.w	snd_none-.tab, snd_11-.tab, snd_12-.tab, snd_13-.tab
	dc.w	snd_14-.tab, snd_none-.tab, snd_16-.tab, snd_17-.tab

; PAD n: burn exactly n cycles (n = 0, or even and >= 4); clobbers N,Z,V,C (not X)
PAD		macro
		if (\1)>0
		if ((\1)%4)=2
		rept	((\1)-6)/4
		nop
		endr
		cmp.l	d2,d2			; 6
		else
		rept	(\1)/4
		nop
		endr
		endif
		endif
		endm

; DELAY n: burn exactly n cycles using d2 for long delays (n even, n = 0 or >= 4)
DELAY		macro
		if (\1)<64
		PAD	\1
		else
		move.w	#(((\1)-22-4)/10),d2	; 8
.d\@:		dbra	d2,.d\@			; 10 per pass, 14 at the end
		PAD	(\1)-22-10*(((\1)-22-4)/10)
		endif
		endm

; FIXED cmd, E, work: pad a cheap command to 266 + E*94 cycles in total.
; The caller has done "work" cycles of command work; we add the poll residue
; (20) and the epilogue (24).
FIXED		macro
		move.w	#($2710-1-(\1)),POLLVAR+2	; 20
		DELAY	(266+(\1)*94-172-24-20-(\2))
		move.l	(sp)+,d1		; 12
		jmp	SEND_EXIT		; 12
		endm

snd_none:				; unused commands: "UNUSED HRQCMD", no 68k-visible effect
	FIXED	1,0
snd_01:					; system init: no 68k-visible effect
	FIXED	E_CMD01,0
snd_02:	FIXED	E_CMD02,0
snd_03:	move.w	#1,SHWIN+$20		; 20  reset flag never left set
	FIXED	E_CMD03,20
snd_04:	clr.w	SHWIN+$20		; 20  message queue always empty
	FIXED	E_CMD04,20
snd_09:	move.l	SHWIN+$20,HLEV+GLOB	; 36
	move.l	SHWIN+$24,HLEV+GLOB+4	; 36
	FIXED	E_CMD09,72
snd_0a:	move.l	SHWIN+$20,HLEV+GLOB+8	; 36
	move.l	SHWIN+$24,HLEV+GLOB+12	; 36
	FIXED	E_CMD0A,72
snd_16:	clr.w	SHWIN+$22		; 20  RAM test passed
	FIXED	E_CMD16,20
snd_17:	clr.w	SHWIN+$22		; 20
	FIXED	E_CMD17,20

; variable wait: d2.w = E (>= 2), "work" = cycles spent since the dispatch.
; total = 172 + work + 44 + (E-1)*94 + 4 + pad + 24 = 266 + E*94  ->  pad = 116 - work
WAITE		macro
		move.w	#$270f,POLLVAR+2	; 20
		sub.w	d2,POLLVAR+2		; 20  residue = $2710 - (E+1)
		subq.w	#2,d2			;  4  E-1 passes
.w\@:		cmp.l	VBLCNT,d1		; 22
		bne.s	.irq\@			;  8
		PAD	54
		dbra	d2,.w\@			; 10 / 14
		PAD	(116-(\1))
		move.l	(sp)+,d1		; 12
		jmp	SEND_EXIT		; 12
.irq\@:		; vblank fired during the wait: like the original, stop at the next poll
		addq.w	#1,d2
		add.w	d2,POLLVAR+2		; fewer polls were made
		move.l	(sp)+,d1
		jmp	SEND_EXIT
		endm

; cmd 12 / 13: the ARM accepts the job and runs it in the background, while the 68k
; idles; we run it in the game's idle loop (hle_idle) or, failing that, at cmd 14.
snd_13:	move.w	#$13,HLEV+PENDING	; 20
	bra.s	snd_1213		; 10
snd_12:	move.w	#$12,HLEV+PENDING	; 20
	PAD	10			; 10  (same path length as snd_13)
snd_1213:
	move.w	SHWIN+$1F00,d2		; 16  number of requests
	andi.w	#$7f,d2			;  8
	move.l	a0,-(sp)		; 12
	lea	E12TAB,a0		; 12
	move.b	(a0,d2.w),d2		; 14
	movea.l	(sp)+,a0		; 12
	andi.w	#$ff,d2			;  8  = 112 since dispatch
	WAITE	112
E12TAB:	E12TAB_DATA			; extra polls for cmd 12 by request count
	even

; cmd 14, no idle time since cmd 12 (slowdown): do the work now (not cycle matched)
snd_14_late:
	movem.l	d0-d7/a0-a6,-(sp)
	bsr	hle_run_job
	movem.l	(sp)+,d0-d7/a0-a6
	move.w	#1,SHWIN+$20
	move.w	HLEV+E14,d2
	move.w	#$270f,POLLVAR+2
	sub.w	d2,POLLVAR+2
	move.l	(sp)+,d1
	jmp	SEND_EXIT

; cmd 14: results are already in the shared window (packed in the idle loop)
snd_14:	tst.w	HLEV+PENDING		; 16
	bne.s	snd_14_late		;  8
	move.w	#1,SHWIN+$20		; 20  done
	move.w	HLEV+E14,d2		; 16  = 60
	WAITE	60

; cmd 11: EST reset, once at start-up (not cycle matched)
snd_11:	movem.l	d0-d7/a0-a6,-(sp)
	lea	HLEV,a5
	lea	SHWIN,a4
	bsr	cmd_11
	movem.l	(sp)+,d0-d7/a0-a6
	move.w	#($2710-1-E_CMD11),POLLVAR+2
	move.l	(sp)+,d1
	jmp	SEND_EXIT

; ---------------------------------------------------------------------------
; hle_idle
; Reached once per frame from the game's "wait for vblank" routine, at the point
; where its message queue is drained and it starts polling (hook: "bra.s" ->
; trampoline "jmp"). That polling loop has a fixed period of 330 cycles, so
; delaying its start by exactly 330 changes nothing: frames without a job cost
; exactly one period. With a job pending we run it here, where the ARM ran it.
; ---------------------------------------------------------------------------
hle_idle:				; 10 (bra.s) + 12 (jmp)
	tst.w	HLEV+PENDING		; 16
	beq.s	.none			; 10 taken
	movem.l	d0-d7/a0-a6,-(sp)
	bsr	hle_run_job
	movem.l	(sp)+,d0-d7/a0-a6
	jmp	IDLE_RESUME
.none:	PAD	(330-12-16-10-12)	; one full polling-loop period in total
	jmp	IDLE_RESUME		; 12

; pack the results only (test benches that resynchronise state per command)
hle_pack:
	lea	HLEV,a5
	lea	SHWIN,a4
	bra	est_results

; run the pending job (cmd 12: update, cmd 13: animate) and pack the results
hle_run_job:
	lea	HLEV,a5
	lea	SHWIN,a4
	move.w	PENDING(a5),d0
	clr.w	PENDING(a5)
	cmpi.w	#$13,d0
	beq.s	.anim
	bsr	cmd_12
	bra	est_results
.anim:	bsr	cmd_13
	bra	est_results

; ---------------------------------------------------------------------------
; hle_bootcheck
; Entered by "jmp" in place of the game's start-up latch check (it clears d2,
; reads the latch into it and branches when ready). The ARM is always ready by then (latch
; $81), so the original reaches BOOT_EXIT 94 cycles after the hook. We set up
; what the firmware has prepared: the region word at shared RAM offset 0 (the
; rest of the ARM-side state is zero at power-on, like main RAM in MAME), and
; replay the original's local variable store.
; ---------------------------------------------------------------------------
hle_bootcheck:				; 12 (jmp)
	move.l	#0,SHWIN		; 28  region word: words +0 = low, +2 = high; the immediate
					;     is filled in at build time from the ARM internal ROM
					;     (patch "region", tools/ddp2bl_build.py)
	move.l	#$c350,-4(a6)		; 24
	moveq	#0,d2			;  4
	move.b	#$81,d2			;  8
	PAD	6
	jmp	BOOT_EXIT		; 12  = 94


; ---------------------------------------------------------------------------
; hle_latch_write
; Replaces the sequence-byte post to the latch in send(). The 68k has stored the command
; word at SHWIN+$10 and is about to post sequence byte $808C9C.
; Behaves like the ARM FIQ: performs the command, clears SHWIN+$10 and leaves
; the echo (next expected sequence) in LATCH, where the unmodified poll loop
; picks it up on its first read.
; Preserves all registers and the condition codes of the replaced MOVE.
; ---------------------------------------------------------------------------
hle_latch_write:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	HLEV,a5
	lea	SHWIN,a4
	moveq	#0,d0
	move.b	SEQVAR,d0		; sequence byte posted by the 68k
	move.b	d0,d1
	addq.b	#1,d1
	andi.b	#$7f,d1
	cmpi.b	#$80,d0			; ($80 = (re)start handshake -> echo 1)
	bne.s	.seq
	moveq	#1,d1
.seq:	move.b	d1,LATCH(a5)
	move.w	$10(a4),d0		; command word
	cmpi.w	#$17,d0
	bhi.s	.done			; firmware would hang; never happens
	add.w	d0,d0
	move.w	.tab(pc,d0.w),d0
	jsr	.tab(pc,d0.w)
.done:	clr.w	$10(a4)
	movem.l	(sp)+,d0-d7/a0-a6
	; condition codes as left by the replaced byte move
	tst.b	SEQVAR
	rts

.tab:	dc.w	cmd_none-.tab, cmd_01-.tab, cmd_02-.tab, cmd_03-.tab
	dc.w	cmd_04-.tab, cmd_none-.tab, cmd_none-.tab, cmd_none-.tab
	dc.w	cmd_none-.tab, cmd_09-.tab, cmd_0a-.tab, cmd_none-.tab
	dc.w	cmd_none-.tab, cmd_none-.tab, cmd_none-.tab, cmd_none-.tab
	dc.w	cmd_none-.tab, cmd_11-.tab, cmd_12-.tab, cmd_13-.tab
	dc.w	cmd_14-.tab, cmd_none-.tab, cmd_16-.tab, cmd_16-.tab


; ---------------------------------------------------------------------------
; cheap commands (a4 = SHWIN, a5 = HLEV)
; ---------------------------------------------------------------------------
cmd_none:
cmd_01:
cmd_02:
	rts				; system flags only: no 68k-visible effect

cmd_03:	move.w	#1,$20(a4)		; reset flag is never left set: "ready"
	rts

cmd_04:	clr.w	$20(a4)			; message queue is always empty
	rts

cmd_09:	move.l	$20(a4),GLOB(a5)
	move.l	$24(a4),GLOB+4(a5)
	rts

cmd_0a:	move.l	$20(a4),GLOB+8(a5)
	move.l	$24(a4),GLOB+12(a5)
	rts

cmd_16:	clr.w	$22(a4)			; RAM test passed
	rts

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

; cmd 12 / 13: start an EST job; the ARM would run it in the background and it
; always completes before the 68k asks (cmd 14), so it is run here directly.
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

; cmd 14: collect results
cmd_14:	move.w	#1,$20(a4)		; job already done
	bra	est_results

	include	"est_results.s"
	include	"est_spawn.s"
	include	"est_engine.s"
