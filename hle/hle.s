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
DPH		equ	$23A8		; word: DEBT mod 330 (kept with DEBT, read by hle_idle)
E14M3		equ	$23AA		; word: E14 - 3 (the cmd 14 wait loop count)
IRQ_PC		equ	$23AC		; word: low word of the PC an interrupt stacked during a wait
IRQ_D2		equ	$23AE		; word: the wait loop counter it saved
IRQ_E		equ	$23B0		; word: E of that wait
IRQ_S		equ	$23B2		; word: polls the original saved (irq_saved)
IRQ_RET		equ	$23B4		; long: the handler's first return address (IRQ4 / IRQ6)
SSP		equ	$23B8		; long: the game's stack pointer while we run on PSTACK
SAVEW		equ	$23BC		; word (+ a word of scratch): the dead-stack word under the sentinel
POLLW		equ	$23C0		; word: $270F - E14 (the cmd 14 poll residue)
PSTACK		equ	$28C2		; top of the private stack ($500 bytes from $23C2): our calls
				; during send() and the interrupts taken in the job
HLEV_SIZE	equ	$28C2

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
; Entered by "jmp" from the game's send(cmd) in place of its three instructions that
; load the command, store it to the command word and post the sequence byte to the
; latch (the send hook), with 10(a6) = command word. Times below count from the start
; of the original's command-word store (our jmp starts at -16). In the reference (protected set,
; per-cycle interleave) the ARM replies D cycles after the latch write; the 68k polls
; first after FIRST_POLL cycles and then every 94, so it reaches SEND_EXIT after
;     266 + E*94 cycles,   E = extra polls = ceil((D - 146) / 94)
; (docs/timing.md; D per command from the calibrated model in target.json).
; We do the command and leave exactly the RAM/register effects of that path:
; seq var += 1 (& $7F), echo var = new seq, status var = 0, poll counter =
; $2710 - (E+1), d0.b = new seq (upper d0 unchanged), d1 unchanged, X = 0; d2 is
; free (the game's epilogue at SEND_EXIT restores it).
;
; The wait is laid out like the original's: the original reads the latch at
; T_k = 172 + 94(k-1), k = 1..E+1, and returns 94 cycles after the read that
; succeeds. Pass 1 (from T_1, per command: the command's work) is followed by
; send_wait (passes 2..E, 94 cycles each, starting exactly at T_k) and the last
; pass, so every T_k is an instruction boundary here too.
;
; Interrupts during the wait. In the original, an interrupt taken before the read at
; T_k (and after the latch write) delays that read by the handler's run time; if the
; ARM has replied by then, send() returns after fewer polls: after poll
; k* = max(k, E+1-skip), skip = the polls the handler covers (IRQ4, ~664 cycles: 7;
; the vblank handler: all). We do not end early (the command's work does not fit):
; the send keeps its length and the 94*(E+1-k*) cycles it is late are added to DEBT,
; which hle_idle repays. The interrupt is found afterwards from its stack frame: a
; sentinel word (0) at -2(sp), armed where the original posts the latch, is
; overwritten by the stacked PC (its low word, never 0 in this code), which locates
; the interrupted instruction (and, in send_wait, the loop counter the handler saved
; gives the pass); the handler's first return address tells IRQ4 from IRQ6 (irq_saved
; in job.s). The stack pointer stays where the original has it, so an interrupt's
; frame lands where it lands there.
;
; Dead stack. The original writes nothing below its stack pointer while it waits.
; The word the sentinel covers is kept in d2.hi from the prologue (then in SAVEW) and
; put back after the check, and our own calls (the job, irq_saved) run on a private
; stack (PSTACK), so a send that no interrupt hit leaves the dead stack untouched.
; Cycle counts per instruction are in the comments (MC68000 manual tables).
; ---------------------------------------------------------------------------
hle_send:				; -16 + 12 (the jmp that got us here; the original's
	nop				;  4  -> 0   command load takes 16)
	move.w	-2(sp),d2		; 12  -> 12  the dead-stack word the sentinel covers
	swap	d2			;  4  -> 16  (interrupts taken by here precede the post)
	clr.w	-2(sp)			; 16  -> 32  sentinel
	move.w	10(a6),d2		; 12  -> 44  d2 = saved word : command
	move.b	SEQVAR,d0		; 16
	addq.b	#1,d0			;  4  (X = 0: seq <= $80)
	andi.b	#$7f,d0			;  8
	move.b	d0,SEQVAR		; 16
	clr.w	STATUSVAR		; 20
	move.b	d0,ECHOVAR		; 16
	move.b	d0,HLEV+LATCH		; 16  (read only by the game's error helper)
	add.w	d2,d2			;  4
	move.w	SEND_TAB(pc,d2.w),d2	; 14
	jmp	SEND_TAB(pc,d2.w)	; 14  = 172 = T_1, the original's first latch read
SEND_TAB:				; (irq_saved: an interrupt at an entry is before read 1)
	dc.w	snd_none-SEND_TAB, snd_01-SEND_TAB, snd_02-SEND_TAB, snd_03-SEND_TAB
	dc.w	snd_04-SEND_TAB, snd_none-SEND_TAB, snd_none-SEND_TAB, snd_none-SEND_TAB
	dc.w	snd_none-SEND_TAB, snd_09-SEND_TAB, snd_0a-SEND_TAB, snd_none-SEND_TAB
	dc.w	snd_none-SEND_TAB, snd_none-SEND_TAB, snd_none-SEND_TAB, snd_none-SEND_TAB
	dc.w	snd_none-SEND_TAB, snd_11-SEND_TAB, snd_12-SEND_TAB, snd_13-SEND_TAB
	dc.w	snd_14-SEND_TAB, snd_none-SEND_TAB, snd_16-SEND_TAB, snd_17-SEND_TAB
SEND_TABN	equ	24

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

; MODDEBT Dn: HLEV+DPH = HLEV+DEBT mod 330, in constant time (580 cycles); clobbers Dn
MODSTEPR	macro
		cmpi.l	#(330<<\2),\1		; 14
		bcs.s	.s\@			; 10 / 8
		subi.l	#(330<<\2),\1		; 16
		bra.s	.j\@			; 10
.s\@:		PAD	24
.j\@:
		endm
MODDEBT		macro
		move.l	HLEV+DEBT,\1		; 20
		addi.l	#330*512,\1		; 16  (keeps it positive; 330*512 = 0 mod 330)
		MODSTEPR	\1,10
		MODSTEPR	\1,9
		MODSTEPR	\1,8
		MODSTEPR	\1,7
		MODSTEPR	\1,6
		MODSTEPR	\1,5
		MODSTEPR	\1,4
		MODSTEPR	\1,3
		MODSTEPR	\1,2
		MODSTEPR	\1,1
		MODSTEPR	\1,0			; 528
		move.w	\1,HLEV+DPH		; 16
		endm

; P1END E, work: end of a pass-1 handler (it started at T_1 with d2.hi = the saved word
; and has spent "work" cycles).
;   E = 1: the last pass follows inline, as in SEND_LAST (sentinel check at T_2 + 4,
;          the same interrupt path), restoring the word from d2.hi.
;   E > 1: keep the word in SAVEW, set the poll residue, continue with send_wait.
P1END		macro
		if (\1)=1
		PAD	(94-(\2))
		swap	d2			;  4  d2.w = the saved word (T_2 + 4)
		tst.w	-2(sp)			; 12  interrupted during the wait?
		bne.s	.i\@			;  8 / 10
		move.w	d2,-2(sp)		; 12  dead-stack word back
		move.w	#($270f-(\1)),POLLVAR+2	; 20  residue = $2710 - (E+1)
		PAD	(94-4-12-8-12-20-12)
		jmp	SEND_EXIT		; 12  = T_2 + 94 = 266 + 94E
.i\@:		moveq	#\1,d2			;  4  E (as SEND_LAST's interrupt path: 34 to send_irq)
		PAD	20
		bra	send_irq		; 10
		else
		move.l	d2,HLEV+SAVEW		; 20  SAVEW = d2.hi
		move.w	#($270f-(\1)),POLLVAR+2	; 20  residue = $2710 - (E+1)
		moveq	#(\1)-2,d2		;  4  pass 2: d2 = E - 2
		PAD	(94-(\2)-20-20-4-10)
		bra	send_wait		; 10
		endif
		endm

SEND_P1:				; pass-1 handlers (irq_saved: k = 2 here, 1 at an entry)
snd_none:				; unused commands: "UNUSED HRQCMD", no 68k-visible effect
	P1END	1,0
snd_01:					; system init: no 68k-visible effect. The first one after
	tst.w	HLEV+BOOTED		; 16	power-on is the ARM's resynchronisation, a
	bne.s	.again			; 10 / 8	longer path (E_CMD01BOOT >= 2).
	move.w	#1,HLEV+BOOTED		; 20
	clr.w	HLEV+PENDING		; 20  (stale after a power cycle)
	clr.l	HLEV+DEBT		; 28
	clr.w	HLEV+DPH		; 20
	move.l	d2,HLEV+SAVEW		; 20
	move.w	#($270f-E_CMD01BOOT),POLLVAR+2	; 20
	PAD	(94*E_CMD01BOOT+4-(16+8+20+20+28+20)-20-20-10)
	bra	SEND_LAST		; 10  last pass, at T_(E+1) + 4
.again:	P1END	E_CMD01,(16+10)
snd_02:	P1END	E_CMD02,0
snd_03:	move.w	#1,SHWIN+$20		; 20  reset flag never left set
	P1END	E_CMD03,20
snd_04:	clr.w	SHWIN+$20		; 20  message queue always empty
	P1END	E_CMD04,20
snd_09:	move.l	SHWIN+$20,HLEV+GLOB	; 36
	move.l	SHWIN+$24,HLEV+GLOB+4	; 36
	P1END	E_CMD09,72
snd_0a:	move.l	SHWIN+$20,HLEV+GLOB+8	; 36
	move.l	SHWIN+$24,HLEV+GLOB+12	; 36
	P1END	E_CMD0A,72
snd_16:	clr.w	SHWIN+$22		; 20  RAM test passed
	P1END	E_CMD16,20
snd_17:	clr.w	SHWIN+$22		; 20
	P1END	E_CMD17,20

; cmd 12 / 13: the ARM accepts the job and runs it in the background while the 68k
; carries on with its frame; on the 68000 it runs at the next cmd 14 (snd_14_job).
snd_13:	move.w	#$13,HLEV+PENDING	; 20  (a job left pending is run by cmd 14 first)
	bra.s	snd_1213		; 10
snd_12:	move.w	#$12,HLEV+PENDING	; 20
	PAD	10			; 10  (same path length as snd_13)
snd_1213:
	move.w	SHWIN+$1F00,d2		; 16  number of requests (d2.hi: the saved word)
	andi.w	#$7f,d2			;  8
	move.b	E12TAB(pc,d2.w),d2	; 14  E (>= 2; d2.w < $80)
	subq.w	#2,d2			;  4  pass 2: d2 = E - 2
	PAD	(94-30-16-8-14-4-10)
	bra	send_wait_pv		; 10
E12TAB:	E12TAB_DATA			; extra polls for cmd 12 by request count (8-bit reach)
	even

; cmd 14: PENDING 0 = results ready; $12 / $113 = a job to run here; $13 = the ARM is
; still animating after cmd 13 (busy answer).
snd_14:	cmpi.w	#$13,HLEV+PENDING	; 20
	beq.s	snd_14_busy		; 10 / 8
	tst.w	HLEV+PENDING		; 16
	bne	snd_14_job		; 10 / 12
	move.w	#1,SHWIN+$20		; 20  done
	move.l	d2,HLEV+SAVEW		; 20
	move.w	HLEV+POLLW,POLLVAR+2	; 28  residue = $2710 - (E+1)
	move.w	HLEV+E14M3,d2		; 16
	; the handler covers passes 1 and 2 (E14 >= 40: whether an interrupt in its second
	; half counts as before read 2 or read 3 changes nothing, 7 polls are saved either way)
	PAD	(2*94-20-8-16-12-20-20-28-16-10)
	bra	send_wait		; 10  pass 3, d2 = E - 3

; cmd 14 right after cmd 13: the game sends it ~2400 cycles after cmd 13, while the
; ARM is still running the animation job (3870-4030 ARM cycles, measured), so the
; ARM answers "not done" at once and packs nothing; the game waits ~18700 cycles and
; asks again (the job has long finished by then). Mark the job as reported busy
; ($113: hle_run_job only looks at the low byte); the next cmd 14 runs it.
snd_14_busy:				; 30 cycles after T_1
	move.w	#$113,HLEV+PENDING	; 20
	clr.w	SHWIN+$20		; 20  not done
	P1END	E_CMD14BUSY,(30+40)

SEND_WAITS:
; pass 2 of cmd 12/13 (at T_2, d2.w = E - 2, d2.hi = the saved word): keep the word,
; set the residue, then the rest of a send_wait pass
send_wait_pv:
	move.l	d2,HLEV+SAVEW		; 20
	move.w	#$270d,POLLVAR+2	; 20
	sub.w	d2,POLLVAR+2		; 20  residue = $270d - (E - 2) = $2710 - (E+1)
	PAD	6
	bra.s	send_wait_8		; 10  (76 of the pass's 84)
; passes 2..E: pass k starts here exactly at T_k with d2.w = E - k
send_wait:
	PAD	76
send_wait_8:
	PAD	8
	dbra	d2,send_wait		; 10 / 14
SEND_LAST:				; last pass (E+1), from T_(E+1) + 4
	tst.w	-2(sp)			; 12  interrupted during the wait?
	bne.s	.irq			;  8 / 10
	move.w	HLEV+SAVEW,-2(sp)	; 24  dead-stack word back
	PAD	(94-4-12-8-24-12)
	jmp	SEND_EXIT		; 12  = T_(E+1) + 94 = 266 + 94E
.irq:	move.w	#$270f,d2		;  8
	sub.w	POLLVAR+2,d2		; 16  E
	PAD	10			; 10  (as "bra send_irq")
send_irq:				; T_(E+1) + 60, d2.w = E
	move.w	-2(sp),HLEV+IRQ_PC	; 24  stacked PC (low word)
	move.w	-56(sp),HLEV+IRQ_D2	; 24  d2 saved by the handler's movem.l d0-d7/a0-a6
	move.l	-70(sp),HLEV+IRQ_RET	; 32  return address of the handler's first jsr
	move.w	d2,HLEV+IRQ_E		; 16
	move.l	sp,HLEV+SSP		; 20
	lea	HLEV+PSTACK,sp		; 12  private stack: below sp is the interrupt's frame
	move.l	a3,-(sp)		; 12
	suba.l	a3,a3			;  8
	bsr	irq_saved		; 18  (+ a3)
	move.w	HLEV+IRQ_S,d2		; 16  polls saved
	mulu.w	#94,d2			; 52  (38 + 2 * 5 bits + #)
	add.l	a3,d2			;  8
	addi.l	#IRQ_FIX,d2		; 16
	add.l	d2,HLEV+DEBT		; 28
	MODDEBT	d2			; 580
	move.w	HLEV+IRQ_E,d2		; 16
	sub.w	HLEV+IRQ_S,d2		; 16  polls made - 1
	move.w	#$270f,POLLVAR+2	; 20
	sub.w	d2,POLLVAR+2		; 20  residue = $2710 - polls made (X = 0)
	movea.l	(sp)+,a3		; 12
	movea.l	HLEV+SSP,sp		; 20
	jmp	SEND_EXIT		; 12
; this path (a3 aside) ends 60 + IRQ_PATH cycles after T_(E+1), the normal one 94 after
IRQ_PATH	equ	24+24+32+16+20+12+12+8+18+16+52+8+16+28+580+16+16+20+20+12+20+12
IRQ_FIX		equ	60+IRQ_PATH-94

; cmd 14 with the job pending: the ARM ran it concurrently with the 68k's game code
; between cmd 12 and cmd 14; on the 68000 it runs here, on the private stack. Its exact
; cost (a3, from the cycle accounting in job.s) minus what the original spent in this
; send() (266 + E*94) is added to DEBT, which hle_idle repays modulo the 330-cycle
; polling period so that the frame's vblank lands in the polling loop exactly as in
; the original. No sentinel check: interrupts during the job push their frames on the
; private stack.
snd_14_job:				; T_1 + 54
	swap	d2			;   4
	move.w	d2,-2(sp)		;  12  dead-stack word back
	move.l	sp,HLEV+SSP		;  20
	lea	HLEV+PSTACK,sp		;  12
	movem.l	d0-d7/a0-a6,-(sp)	; 128
	suba.l	a3,a3			;   8
	move.l	a3,HLEV+PROBE		;  20  probe 0
	bsr	hle_run_job		;  18  (+ a3)
	move.l	a3,HLEV+PROBE+4		;  20  probe 1
	move.l	a3,d0			;   4
	move.w	HLEV+E14,d1		;  16
	mulu.w	#94,d1			;  52
	sub.l	d1,d0			;   8
	addi.l	#JOB_FIX,d0		;  16
	add.l	d0,HLEV+DEBT		;  28
	MODDEBT	d0			; 580
	move.w	#1,SHWIN+$20		;  20  done
	move.w	HLEV+POLLW,POLLVAR+2	;  28  residue = $2710 - (E+1)
	movem.l	(sp)+,d0-d7/a0-a6	; 132
	movea.l	HLEV+SSP,sp		;  20
	jmp	SEND_EXIT		;  12
;   debt = a3 + (172 + 54 + fixed cycles here) - 266 - 94*E
JOB_FIX		equ	172+54+4+12+20+12+128+8+20+18+20+4+16+52+8+16+28+580+20+28+132+20+12-266

; cmd 11: EST reset, once at start-up (E_CMD11 polls in the original)
snd_11:	swap	d2			;   4
	move.w	d2,-2(sp)		;  12  dead-stack word back
	move.l	sp,HLEV+SSP		;  20
	lea	HLEV+PSTACK,sp		;  12
	movem.l	d0-d7/a0-a6,-(sp)	; 128
	lea	HLEV,a5			;  12
	lea	SHWIN,a4		;  12
	suba.l	a3,a3			;   8
	bsr	cmd_11			;  18  (+ a3)
	move.l	a3,d0			;   4
	addi.l	#C11_FIX,d0		;  16
	add.l	d0,HLEV+DEBT		;  28
	MODDEBT	d0			; 580
	movem.l	(sp)+,d0-d7/a0-a6	; 132
	movea.l	HLEV+SSP,sp		;  20
	move.w	#($2710-1-E_CMD11),POLLVAR+2	; 20
	jmp	SEND_EXIT		;  12
C11_FIX		equ	172+4+12+20+12+128+12+12+8+18+4+16+28+580+132+20+20+12-266-94*E_CMD11

; ---------------------------------------------------------------------------
; hle_idle
; Reached once per frame from the game's "wait for vblank" routine, at the point
; where its message queue is drained and it starts polling (hook: "bra.s" ->
; trampoline "jmp"). The polling loop (IDLE_L0..) takes 330 cycles per pass: test the
; callback count, call the one callback (IDLE_CB, the once-a-minute clock watch),
; compare the vblank counter. The original entered it at the counter compare (pass
; offset 298) DEBT cycles ago, so it is now at pass offset 310 + DEBT (mod 330)
; (310 = 298 + our entry, 22 cycles, minus its bra, 10).
; We continue the original loop from exactly there: each table entry (by DEBT mod 330,
; kept in DPH with DEBT) selects an instruction boundary of the pass and a short pad;
; the stub sets up what the original has at that point (the callback index, d0/a0/a1,
; the callback's stack frame) and jumps in. From then on the 68000 runs the original
; instructions in the original's phase, so the vblank interrupt lands exactly as there.
; 380 + pad + setup cycles separate our arrival from that point (before: 910 + D).
; With another callback set (not seen in play) the old way: delay until the loop's
; compare is in phase.
; ---------------------------------------------------------------------------
hle_idle:				; 12 (trampoline jmp; the hooked bra.s costs 10 like the original)
	move.l	IDLE_CBN,d0		; 20  callbacks registered
	subq.l	#1,d0			;  8
	bne.w	.leg1			; 10 / 12
	move.l	IDLE_CBTAB,d0		; 20  the callback
	cmpi.l	#IDLE_CB,d0		; 14
	bne.w	.leg2			; 10 / 12   (86)
	; A vblank the callback has not seen yet (the last frame left the loop before its
	; callback ran): the original's first call took the long path (84 cycles more,
	; "last vblank" updated, countdown decremented). Do its effects; when the countdown
	; is out (the once-a-minute clock read) run the original way instead.
	move.l	VBLCNT,d1		; 20
	cmp.l	IDLE_LAST,d1		; 22
	beq.s	.np			; 10 / 8
	tst.l	IDLE_CNTDN		; 20
	beq.w	.leg3			; 10 / 12
	move.l	d1,IDLE_LAST		; 20
	subq.l	#1,IDLE_CNTDN		; 28
	move.w	#2*330,d1		;  8  table quarter: pending
	bra.s	.q			; 10  (234)
.np:	moveq	#0,d1			;  4
	PAD	92			;     (138 + 96 = 234)
.q:	move.w	HLEV+DPH,d0		; 16
	add.w	d1,d0			;  4
	clr.l	HLEV+DEBT		; 28
	clr.w	HLEV+DPH		; 20  (302)
	; the first pass after entry also skips the index clear (26 cycles) when the index
	; was 0, as it usually is at entry
	tst.l	IDLE_IDX		; 20
	bne.s	.v1			; 10 / 8
	addi.w	#330,d0			;  8  table quarter: index 0
	bra.s	.ix			; 10
.v1:	PAD	16
.ix:	add.w	d0,d0			;  4  (348)
	move.w	.etab(pc,d0.w),d0	; 14
	jmp	.etab(pc,d0.w)		; 14  = 380 to the stub
.etab:	IDLE2TAB_DATA

.leg1:	PAD	46			; 38 + 46 = 84
.leg2:	PAD	82			; 84 + 82 = 166
.leg3:
.leg:					; 166
	movem.l	d0-d2,-(sp)		;  32
	move.l	HLEV+DEBT,d0		;  20
	move.l	d0,HLEV+PROBE+8		;  20  probe 2: debt
	clr.l	HLEV+DEBT		;  28
	clr.w	HLEV+DPH		;  20
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
	jmp	IDLE_RESUME		;  12   total 910 + D = -debt (mod 330)

; idle stubs: IDLE_SLED nops (the table enters after some of them), then the state the
; original has at that pass offset, then a jump into its loop. Setup cycles (with the
; jmp) are in target.json "idle_loop" (gen_target_inc.py builds the table from them).
ISET1		macro			; callback index 1 (before the loop's clear): 24
		moveq	#1,d0			;  4
		move.l	d0,IDLE_IDX		; 20
		endm
ISET0		macro			; callback index 0 (between its clear and increment): 28
		clr.l	IDLE_IDX		; 28
		endm
ISLED		macro
		rept	IDLE_SLED
		nop
		endr
		endm
; each boundary has two stubs: IST<b> (pad 4m) and ISTB<b> (pad 4m + 6)
IST0:	ISLED
	ISET1
	jmp	IDLE_L0			; 12  = 36
ISTB0:	ISLED
	cmp.l	d2,d2			;  6
	ISET1
	jmp	IDLE_L0			; 12  = 36
IST28:	ISLED
	ISET1
	jmp	IDLE_L28		; 36
ISTB28:	ISLED
	cmp.l	d2,d2			;  6
	ISET1
	jmp	IDLE_L28		; 36
IST48:	ISLED
	ISET1				; (d0 = 1 = the index the loop just loaded)
	jmp	IDLE_L48		; 36
ISTB48:	ISLED
	cmp.l	d2,d2			;  6
	ISET1				; (d0 = 1 = the index the loop just loaded)
	jmp	IDLE_L48		; 36
IST78:	ISLED
	ISET1
	jmp	IDLE_L78		; 36
ISTB78:	ISLED
	cmp.l	d2,d2			;  6
	ISET1
	jmp	IDLE_L78		; 36
IST106:	ISLED
	ISET0
	jmp	IDLE_L106		; 40
ISTB106:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	jmp	IDLE_L106		; 40
IST122:	ISLED
	ISET0
	moveq	#0,d0			;  4
	jmp	IDLE_L122		; 44
ISTB122:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	moveq	#0,d0			;  4
	jmp	IDLE_L122		; 44
IST132:	ISLED
	ISET0
	moveq	#0,d0			;  4
	jmp	IDLE_L132		; 44
ISTB132:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	moveq	#0,d0			;  4
	jmp	IDLE_L132		; 44
IST144:	ISLED
	ISET0
	moveq	#0,d0			;  4
	movea.l	#IDLE_CBTAB,a1		; 12
	jmp	IDLE_L144		; 56
ISTB144:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	moveq	#0,d0			;  4
	movea.l	#IDLE_CBTAB,a1		; 12
	jmp	IDLE_L144		; 56
IST162:	ISLED
	ISET0
	movea.l	#IDLE_CB,a0		; 12
	jmp	IDLE_L162		; 52
ISTB162:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	movea.l	#IDLE_CB,a0		; 12
	jmp	IDLE_L162		; 52
IST178:	ISLED
	ISET0
	pea	IDLE_RET		; 20  (jsr (a0) pushed this)
	jmp	IDLE_CB			; 60
ISTB178:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	pea	IDLE_RET		; 20  (jsr (a0) pushed this)
	jmp	IDLE_CB			; 60
IST190:	ISLED
	ISET0
	pea	IDLE_RET		; 20
	move.l	d2,-(sp)		; 12  (the callback saved d2)
	jmp	IDLE_C12		; 72
ISTB190:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	pea	IDLE_RET		; 20
	move.l	d2,-(sp)		; 12  (the callback saved d2)
	jmp	IDLE_C12		; 72
IST210:	ISLED
	ISET0
	pea	IDLE_RET		; 20
	move.l	d2,-(sp)		; 12
	move.l	VBLCNT,d2		; 20
	jmp	IDLE_C32		; 92
ISTB210:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	pea	IDLE_RET		; 20
	move.l	d2,-(sp)		; 12
	move.l	VBLCNT,d2		; 20
	jmp	IDLE_C32		; 92
IST242:	ISLED
	ISET0
	pea	IDLE_RET		; 20
	move.l	d2,-(sp)		; 12
	move.l	VBLCNT,d2		; 20
	jmp	IDLE_C64		; 92
ISTB242:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	pea	IDLE_RET		; 20
	move.l	d2,-(sp)		; 12
	move.l	VBLCNT,d2		; 20
	jmp	IDLE_C64		; 92
IST254:	ISLED
	ISET0
	pea	IDLE_RET		; 20
	jmp	IDLE_C76		; 60
ISTB254:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	pea	IDLE_RET		; 20
	jmp	IDLE_C76		; 60
IST270:	ISLED
	ISET0
	jmp	IDLE_RET		; 40
ISTB270:	ISLED
	cmp.l	d2,d2			;  6
	ISET0
	jmp	IDLE_RET		; 40
IST298:	ISLED
	ISET1
	jmp	IDLE_RESUME		; 36
ISTB298:	ISLED
	cmp.l	d2,d2			;  6
	ISET1
	jmp	IDLE_RESUME		; 36


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

