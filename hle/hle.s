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
; hle_boot: called once before the game's first ASIC access; sets up the
; state the ARM firmware has established by then (all-zero work RAM, region
; word in shared RAM, "ready" latch).
; ---------------------------------------------------------------------------
hle_boot:
	movem.l	d0/a0-a1,-(sp)
	lea	SHWIN,a0
	move.w	#SHWIN_SIZE/4-1,d0
.c1:	clr.l	(a0)+
	dbra	d0,.c1
	lea	HLEV,a0
	move.w	#HLEV_SIZE/4-1,d0
.c2:	clr.l	(a0)+
	dbra	d0,.c2
	lea	SHWIN,a0
	move.l	#REGION_WORD,d0		; ARM u32 at $48000000 -> 68k words +0 (low), +2 (high)
	swap	d0
	move.l	d0,(a0)
	lea	HLEV,a0
	move.b	#$81,LATCH(a0)		; ARM booted and ready
	movem.l	(sp)+,d0/a0-a1
	rts

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
