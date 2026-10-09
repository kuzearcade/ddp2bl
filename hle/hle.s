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
HLEV_SIZE	equ	$238C

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
;     its command-word store and latch post      (at the send hook)
; with d2.l = command. The original then polls the latch once (the ARM always
; answers before the first poll) and reaches the epilogue SEND_EXIT 266 cycles
; after the hook. We perform the command, leave every RAM/register effect the
; original leaves on that path, and arrive at SEND_EXIT after exactly the same
; number of cycles for every command whose work fits (all but 11/12/13/14).
;   effects: seq var += 1 (& $7F), echo var = new seq, status var = 0,
;            poll counter = $270F (= $2710 - 1 poll), d0.b = new seq (upper d0
;            unchanged), X = 0. d2 is free (restored by the epilogue).
;   timing : cycles per instruction in the comments (MC68000 manual tables, as
;            implemented by MAME's cycle-exact 68000 core).
; ---------------------------------------------------------------------------
hle_send:				; 12 (the jmp that got us here)
	move.b	SEQVAR,d0		; 16
	addq.b	#1,d0			;  4  (X = 0: seq <= $80)
	andi.b	#$7f,d0			;  8
	move.b	d0,SEQVAR		; 16
	clr.w	STATUSVAR		; 20
	move.w	#$270f,POLLVAR+2	; 20  (high word is always 0)
	move.b	d0,ECHOVAR		; 16
	move.b	d0,HLEV+LATCH		; 16  (read only by the game's error helper)
	add.w	d2,d2			;  4
	move.w	.tab(pc,d2.w),d2	; 14
	jmp	.tab(pc,d2.w)		; 14  = 160; 266 - 160 - 12 (exit jmp) = 94 left
.tab:	dc.w	snd_none-.tab, snd_none-.tab, snd_none-.tab, snd_03-.tab
	dc.w	snd_04-.tab, snd_none-.tab, snd_none-.tab, snd_none-.tab
	dc.w	snd_none-.tab, snd_09-.tab, snd_0a-.tab, snd_none-.tab
	dc.w	snd_none-.tab, snd_none-.tab, snd_none-.tab, snd_none-.tab
	dc.w	snd_none-.tab, snd_11-.tab, snd_12-.tab, snd_13-.tab
	dc.w	snd_14-.tab, snd_none-.tab, snd_16-.tab, snd_16-.tab

; PAD n: burn exactly n cycles (n even, n >= 4); clobbers N,Z,V,C (not X)
PAD		macro
		if ((\1)%4)=2
		rept	((\1)-6)/4
		nop
		endr
		cmp.l	d2,d2		; 6
		else
		rept	(\1)/4
		nop
		endr
		endif
		endm

snd_none:				; 01, 02, unused: no 68k-visible effect
	PAD	94
	jmp	SEND_EXIT
snd_03:	move.w	#1,SHWIN+$20		; 20  reset flag never left set
	PAD	74
	jmp	SEND_EXIT
snd_04:	clr.w	SHWIN+$20		; 20  message queue always empty
	PAD	74
	jmp	SEND_EXIT
snd_09:	move.l	SHWIN+$20,HLEV+GLOB	; 36
	move.l	SHWIN+$24,HLEV+GLOB+4	; 36
	PAD	22
	jmp	SEND_EXIT
snd_0a:	move.l	SHWIN+$20,HLEV+GLOB+8	; 36
	move.l	SHWIN+$24,HLEV+GLOB+12	; 36
	PAD	22
	jmp	SEND_EXIT
snd_16:	clr.w	SHWIN+$22		; 20  RAM test passed
	PAD	74
	jmp	SEND_EXIT

; heavy commands: full register save, not padded (they run in frames with idle time)
HEAVY		macro
		movem.l	d0-d7/a0-a6,-(sp)
		lea	HLEV,a5
		lea	SHWIN,a4
		bsr	\1
		movem.l	(sp)+,d0-d7/a0-a6
		jmp	SEND_EXIT
		endm
snd_11:	HEAVY	cmd_11
snd_12:	HEAVY	cmd_12
snd_13:	HEAVY	cmd_13
snd_14:	HEAVY	cmd_14

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
