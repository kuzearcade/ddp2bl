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
TMP		equ	$2390		; word: job scratch
PROBE		equ	$2392		; 16 bytes: verification probe writes (MAME DDP2BL_PROBE)
DEBT		equ	$23A2		; long: cycles spent beyond the original (repaid mod 330 at idle)
BOOTED		equ	$23A6		; word: first cmd 01 (ARM resynchronisation) seen
HLEV_SIZE	equ	$23A8

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
snd_01:					; system init: no 68k-visible effect. The first one after
	tst.w	HLEV+BOOTED		; 16	power-on is the ARM's resynchronisation, a longer path.
	bne.s	.again			; 10 / 8
	move.w	#1,HLEV+BOOTED		; 20
	clr.w	HLEV+PENDING		; 20  (stale after a power cycle)
	clr.l	HLEV+DEBT		; 28
	FIXED	E_CMD01BOOT,(16+8+20+20+28)
.again:	FIXED	E_CMD01,(16+10)
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

; cmd 12 / 13: the ARM accepts the job and runs it in the background while the 68k
; carries on with its frame; on the 68000 it runs at the next cmd 14 (snd_14_job).
snd_13:	move.w	#$13,HLEV+PENDING	; 20  (a job left pending is run by cmd 14 first)
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

; cmd 14 with the job pending: the ARM ran it concurrently with the 68k's game code
; between cmd 12 and cmd 14; on the 68000 it runs here. Its exact cost (a3, from the
; cycle accounting in job.s) minus what the original spent in this send() (266 + E*94)
; is added to DEBT, which hle_idle repays modulo the 330-cycle polling period so that
; the frame's vblank lands in the polling loop exactly as in the original.
;   fixed cycles here: 172 (prologue) + 20 + 8 + 16 + 10 + 174 + 376 = 776, so
;   debt = a3 + 776 - 266 - 94*E = a3 + 510 - 94*E
snd_14_job:				; after prologue (172) + cmpi (20) + beq (8) + tst (16) + bne (10)
	movem.l	d0-d7/a0-a6,-(sp)	; 128
	suba.l	a3,a3			;   8
	move.l	a3,HLEV+PROBE		;  20  probe 0
	bsr	hle_run_job		;  18  (+ a3)
	move.l	a3,HLEV+PROBE+4		;  20  probe 1
	move.l	a3,d0			;   4
	move.w	HLEV+E14,d1		;  16
	mulu.w	#94,d1			;  52
	sub.l	d1,d0			;   8
	addi.l	#510,d0			;  16
	add.l	d0,HLEV+DEBT		;  28
	move.w	#1,SHWIN+$20		;  20  done
	move.w	HLEV+E14,d2		;  16
	move.w	#$270f,POLLVAR+2	;  20
	sub.w	d2,POLLVAR+2		;  20  residue = $2710 - (E+1)
	movem.l	(sp)+,d0-d7/a0-a6	; 132
	move.l	(sp)+,d1		;  12
	jmp	SEND_EXIT		;  12

; cmd 14: results are ready (no job pending): exact original timing
snd_14:	cmpi.w	#$13,HLEV+PENDING	; 20
	beq.s	snd_14_busy		;  8 / 10
	tst.w	HLEV+PENDING		; 16
	bne.s	snd_14_job		;  8 / 10
	move.w	#1,SHWIN+$20		; 20  done
	move.w	HLEV+E14,d2		; 16  = 88
	WAITE	88

; cmd 14 right after cmd 13: the game sends it ~2400 cycles after cmd 13, while the
; ARM is still running the animation job (3870-4030 ARM cycles, measured), so the
; ARM answers "not done" at once and packs nothing; the game waits ~18700 cycles and
; asks again (the job has long finished by then). Mark the job as reported busy
; ($113: hle_run_job only looks at the low byte); the next cmd 14 runs it.
snd_14_busy:				; after prologue (172) + cmpi (20) + beq taken (10)
	move.w	#$113,HLEV+PENDING	; 20
	clr.w	SHWIN+$20		; 20  not done
	FIXED	E_CMD14BUSY,(20+10+20+20)

; cmd 11: EST reset, once at start-up: fixed 574 + a3 vs original 266 + 12*94 = 1394
snd_11:	movem.l	d0-d7/a0-a6,-(sp)	; 128
	lea	HLEV,a5			;  12
	lea	SHWIN,a4		;  12
	suba.l	a3,a3			;   8
	bsr	cmd_11			;  18  (+ a3)
	move.l	a3,d0			;   4
	subi.l	#820,d0			;  16
	add.l	d0,HLEV+DEBT		;  28
	movem.l	(sp)+,d0-d7/a0-a6	; 132
	move.w	#($2710-1-E_CMD11),POLLVAR+2	; 20
	move.l	(sp)+,d1		;  12
	jmp	SEND_EXIT		;  12

; ---------------------------------------------------------------------------
; hle_idle
; Reached once per frame from the game's "wait for vblank" routine, at the point
; where its message queue is drained and it starts polling (hook: "bra.s" ->
; trampoline "jmp"). That polling loop has a fixed period of 330 cycles, so
; delaying its start by a multiple of 330 changes nothing. We delay it by
; -DEBT mod 330 (+k*330): the loop then resumes in the phase it had in the
; original, which did not spend the job's time on the 68000.
; ---------------------------------------------------------------------------
hle_idle:				; 12 (trampoline jmp; the hooked bra.s costs 10 like the original)
	movem.l	d0-d2,-(sp)		;  32
	move.l	HLEV+DEBT,d0		;  20
	move.l	d0,HLEV+PROBE+8		;  20  probe 2: debt
	clr.l	HLEV+DEBT		;  28
	addi.l	#330*512,d0		;  16  (keeps it positive; 330*512 = 0 mod 330)
	; d0 mod 330 in constant time (each step 48 cycles either way)
MODSTEP		macro
		cmpi.l	#(330<<\1),d0		; 14
		bcs.s	.s\@			; 10 / 8
		subi.l	#(330<<\1),d0		; 16
		bra.s	.j\@			; 10
.s\@:		PAD	24
.j\@:
		endm
	MODSTEP	10
	MODSTEP	9
	MODSTEP	8
	MODSTEP	7
	MODSTEP	6
	MODSTEP	5
	MODSTEP	4
	MODSTEP	3
	MODSTEP	2
	MODSTEP	1
	MODSTEP	0			; 528
	move.w	.dtab(pc,d0.w),d1	;  14  k:sled  (D = 82 + 10k + 4m, from the table)
	bra	.dtabx			;  10
.dtab:	IDLETAB_DATA
.dtabx:	moveq	#0,d2			;   4
	move.b	d1,d2			;   4
	lsr.w	#8,d1			;  22
.dl:	dbra	d1,.dl			;  10k + 14
	jmp	.sled(pc,d2.w)		;  14
.sled:	rept	DELAY_SLED
	nop				;  4m
	endr
	move.l	d0,HLEV+PROBE+12	;  20  probe 3
	movem.l	(sp)+,d0-d2		;  36
	jmp	IDLE_RESUME		;  12   total 724 + D = -debt (mod 330)

; pack the results only (test benches that resynchronise state per command)
hle_pack:
	lea	HLEV,a5
	lea	SHWIN,a4
	bra	est_results


; ---------------------------------------------------------------------------
; hle_reset
; Called ("jsr", 20) in place of the 1008-cycle delay loop (6 bytes)
; that the game's cold-reset entry runs with interrupts masked. A reset also resets the
; ARM, which then prepares the region word at shared RAM offset 0 and shows "ready"
; ($81) at its latch. The game's start-up check reads that latch (relocated to LATCH):
; $81 once after a reset, afterwards the echo of the last command, exactly as before.
; Main RAM is battery backed, so the rest of our state from a previous session is also
; reset here. Same cycles and the same d0 ($0000FFFF) as the replaced loop.
; ---------------------------------------------------------------------------
hle_reset:				; 20 (jsr)
	move.l	#0,SHWIN		; 28  region word: words +0 = low, +2 = high; the immediate
					;     is filled in at build time from the ARM internal ROM
					;     (patch "region", tools/ddp2bl_build.py)
	move.b	#$81,HLEV+LATCH		;  20
	clr.w	HLEV+BOOTED		;  20
	clr.w	HLEV+PENDING		;  20
	clr.l	HLEV+DEBT		;  28
	moveq	#83,d0			;   4
.d:	dbra	d0,.d			; 830 + 14
	nop				;   4
	nop				;   4
	rts				;  16  = 20 + 116 + 856 + 16 = 1008


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

; cmd 14 for the generic hle_latch_write path (other send() variants): run a pending
; job, then pack. (d6 accumulates cycles there too; nothing reads it on this path.)
cmd_14:	move.w	#1,$20(a4)
	tst.w	PENDING(a5)
	beq	est_results
	bra	hle_run_job

	include	"job_acc.s"		; job.s with cycle accounting (tools/cycacc.py)

