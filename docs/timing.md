# Timing design and measurements

## Reference

The protected set is emulated with **per-cycle CPU interleave** (`DDP2_PERFECT`), speedups
off. Under MAME's default scheduler the ARM's response to the same command varies with
scheduler phase (e.g. 2 or 3 polls for the same cheap command, and spurious "job not done"
answers to cmd 14 that never occur with fine interleave), so the default-scheduler run is not
a deterministic reference. With per-cycle interleave the ARM really runs concurrently with
the 68000, which is what the hardware does.

## How the original spends 68000 time on the ASIC

A gameplay frame (measured): vblank interrupt (the handler takes ~14,000 cycles before it
counts the vblank) → frame start → **09, 0A, 12** → 36,000-49,000 cycles of game code while
the ARM runs the bullet job → **14** (collect) → **04** → the game's vblank wait (idle loop).

`send()` (hook at `$145922`) writes the command, posts the sequence byte to the latch at
+16..+44 cycles, then polls: poll *k* starts at +172 + 94(*k*-1). It returns at
`266 + E*94`, E = extra polls = `ceil((D - 146) / 94)` for an ARM reply D cycles after the
latch write:

| cmd | ARM reply D (cycles) | E |
|---|---|---|
| 01 (first after a reset: ARM resynchronisation) | 254 | 2 |
| 01, 02, 03, 04, 09, 0A | 158-194 | 1 |
| 11, 16, 17 | ~1270 | 12 |
| 12 | 360 + j (n = 0), 356 + 54n + j (n requests) | table |
| 13 | 360 + j | 3 |
| 14 | 4047 + 30·n(1-3) + 54·n4 + 34·n5 + 49·n(6,7) + (2 + 9·removed, if any) + j | from the job |
| 14 right after 13 ("busy", see below) | 160 | 1 |

`j` is ARM-side jitter: {0, 3, 6, 9} for cmd 12 (6 in 77% of sends, 9 in 17%), {0, 3} for
cmd 14 (0 in 82%). It depends on where the ARM's idle loop is when the latch write arrives
(it correlates only with the ARM-internal time since its previous reply), which the 68000
cannot observe. The replacement uses the most frequent value. Measured over the three
60,000-frame reference runs (519,000 interrupt-free cmd 12/14 sends): the poll count is
predicted exactly for 99.95% of cmd 12 and 99.40% of cmd 14 sends; the rest are ±1 poll.

**Busy answer.** After cmd 13 (animation-only job, used e.g. on the continue screen) the
game sends cmd 14 about 2,400 cycles later, while the ARM is still animating (3,871-4,024
cycles measured). The ARM answers "not done" at once without packing, the game busy-waits
1,024 loop passes (~18,700 cycles) and asks again; by then the job has long finished
(17,350+ cycles of margin). The replacement reproduces this (1,514 of 1,514 occurrences).

The ARM can also be busy after cmd 12, when its update job takes longer than the game
code between cmd 12 and cmd 14 (25,000-30,000 cycles in heavy frames). Measured over the
full game: ARM jobs up to 31,434 cycles, often finishing only 900-2,000 cycles before cmd 14,
and once (the final boss's death, 115 bullets turned into debris) 4,722 cycles too late:
the game waited ~18,700 cycles and asked again. The replacement does not model this case
(the 68000 cannot measure the time from cmd 12 to cmd 14 precisely enough: no timer; the
scanline counter has 1,280-cycle steps). Effect: that frame's results are the same, the
original spends ~19,000 more cycles in it, and the protocol sequence byte is one step
apart afterwards (docs/verification.md).

**Interrupts during a send.** An interrupt taken between the latch write and a poll delays
that poll by the handler's run time; if the reply has arrived by then, the send ends with
fewer polls. The vblank handler (IRQ6, ~14,000 cycles) always ends the wait at the next
poll; the scanline-0 handler (IRQ4, ~51,100 cycles into the frame) takes 660-668 cycles
(its autovector acknowledge is synchronised to the 68000 E clock). The replacement's long
waits end at the next poll after an IRQ6 like the original; IRQ4 effects are not modelled
(2.5% of frames have one inside a send; see "residual" below).

## What the 68000 replacement does

* cmds 01-0A, 16/17, the busy 14: the command's effect plus a pad to exactly `266 + E*94`
  cycles, with the same RAM side effects as the original poll loop (sequence/echo bytes,
  status word, poll counter residue).
* cmd 12/13: accept the job (cycle-exact, E from the cmd 12 table).
* cmd 14: run the job and pack the results, then record
  `debt = cost - (266 + E*94)` — extra 68000 time the original did not have (the ARM did
  the work in parallel). The job code is **cycle accounted** (`tools/cycacc.py`), so its
  exact cost is known at run time.
* idle hook (the game's vblank wait, once per frame): burns `-debt mod 330` (+k·330) cycles
  so the 330-cycle polling loop resumes in the original's phase.
* reset hook: the cold-reset entry's 1,008-cycle delay loop (interrupts masked) is replaced
  by a routine of exactly that length that sets up what the ARM does at power-on (region
  word, latch "ready" `$81`). The game's start-up check then runs unmodified against the
  relocated latch: `$81` once after a reset, afterwards the echo of the last command,
  exactly like the original (it is called twice during a boot). The boot timeline is
  identical to the reference up to the first gameplay frame.

## Cycle accounting

`tools/cycacc.py` turns `hle/job.s` into `job_acc.s`. It assigns each basic block a
potential φ (cost to the end of the routine along a chosen path) and inserts
`lea N(a3),a3` only where paths with different costs diverge: on the fall-through edge of a
branch whose taken edge is free, or through an out-of-line stub for a branch marked
`@unlikely` (keeping the common path marker-free). Calls add the callee's potential;
jump-table targets and loop heads are fixed at 0. Two loops account for themselves
(`@cyc-off` regions): the update dispatch and the result packer, which add per-state costs
from their own counts. 171 markers for 298 blocks (was one per block); on the heaviest
job the markers cost 13% before this change.

**Verified against MAME** (`DDP2BL_PROBE`, `tools/probe_check.py`): measured − accounted
= 38 for every job no interrupt hit (1,807 of 1,876 in a 3,000-frame run; the others were
hit by IRQ4). 38 is exactly the probe overhead (`bsr` 18 + `move.l` 20). (The Musashi
bench is not a timing reference for MULS/MULU and `ANDI.L #,Dn`; MAME and the MC68000
manual agree.)

## Is there enough time? (`tools/margin.py`)

On the 68000 the job is extra time between cmd 12 and the vblank wait. The conversion stays
frame-exact as long as that extra time is less than the time the original game had left
before the vblank interrupt in the same frame. From full-length captures of the three
reference runs (57,000-58,000 gameplay frames each) and the job cost of every frame
(`harness/hle_stream_test.py --jobs-out`):

| run | worst frame margin | worst debt / slack | frames the conversion makes late |
|---|---|---|---|
| L1p (1 player, invulnerable, 60,000 frames) | 38,355 cycles | 0.77 | 0 |
| L2p (2 players, invulnerable, 60,000 frames) | 53,471 cycles | 0.66 | 0 |
| Lnc (no cheats, 60,000 frames) | 66,761 cycles | 0.68 | 0 |
| full game (1 player, 145,900 frames, to the ending) | 11,801 cycles | 0.91 | 0 |
| full game (2 players, autofire + bombs, 81,200 frames, to the ending) | 26,967 cycles | 0.80 | 0 |
| full game, no cheats, 1 player (106,000 frames) | 25,905 cycles | 0.77 | 0 |
| full game, no cheats, 2 players (89,000 frames) | 14,023 cycles | 0.88 | 0 |

The tightest frames are at the final boss: the original game itself is in slowdown there
(74,040 of 137,537 job frames of the full game are late in the original), so the
conversion has only until the next vblank interrupt, and the screen is full of bullets
(126 in state 2 at the worst frame). Other bursts are many bullets turning into falling
debris at once. History: a build with a 25% slower job was late by 384 cycles in such a
burst; the next one by 5,317 cycles at the final boss (found by the full-game test). The job
was optimised both times with all outputs unchanged (cycle markers, packer dispatch with
states 1-3 first, update loop counted with `dbra`, a state-2 fast path for bullets whose
script instruction is still running, a tighter free-slot search): the final-boss frame went
from 139,406 to 122,288 cycles. A third pass targeted the frame in which a boss's death turns
every bullet into falling debris (`sp_todebris`: counters and constants in registers, the
animation entry computed once per frame change instead of per object, adjacent fields written
as longs; `st5`'s animation step inline): 165,758 -> 146,726 cycles with 126 bullets (margin
-217 -> 18,815), 159,026 -> 141,612 with 115.

This margin is a property of the inputs, not a guarantee: in a slowdown frame the time
left before the next vblank depends on how much the game itself had to do. A scene heavier
than any in these runs could leave less than the job needs; the game would then drop one
update there (the original would not).

## Residual differences (measured, by design or unavoidable)

* **Sub-frame timing after cmd 14**: the 68000 timeline between cmd 14 and the vblank wait
  is shifted by the job's cost, so the sound CPU sees the frame's later sound commands a few
  thousand cycles later (same commands, same frame). Z80 RAM sampled at the video frame
  boundary differs; sound output is the same commands in the same frames.
* **Z80 handshake waits**: before some sound commands the game polls the Z80 until it is
  ready (`$175976`). Since the Z80 sees those commands at a different sub-frame time, its
  busy periods fall differently and the wait can differ by up to ~56,000 cycles in a frame
  (two-player full game: 16 logical frames). Commands, order and frames are unchanged, and
  no frame was lost or gained in the 1p/2p cheat runs. In the two-player no-cheat run one
  such stall (~217,000 cycles, in the original only) changed how inputs were assigned to
  logical frames and the games diverged; the original diverges the same way from itself
  when its Z80 is detuned by 30 ppm (docs/verification.md), i.e. on real hardware, where the
  Z80 has its own crystal, this is not reproducible anyway.
* **Idle-loop phase**: the phase lock repays the job exactly, but the original's own phase
  also depends on things a 68000 cannot know: the ARM's reply jitter (±1 poll in 0.6% of
  cmd 14 sends) and how long IRQ4's acknowledge takes when it lands in different code. A
  phase difference persists until both sets resynchronise. It changes which instruction
  of the vblank-wait loop the vblank interrupt lands on, nothing in game logic: the game
  advances by frames, reads inputs and sends sound commands in the vblank handler.
  Consequences that show up in RAM:
  - the once-a-minute clock poll (vblank-wait callback `$149DC0`: countdown `$80EE50`,
    last vblank `$80EE54`, clock copy `$80EE40`, and the BIOS running-time record
    `$8021E2-$8021ED` it updates through a BIOS call) can run one frame earlier or later;
  - the poll-counter residue `$80ECAE` (read only by the protocol error reporter);
  - stale stack bytes, and through a game bug VRAM: the background row writer at
    `$13F4C6` stores a tile as a long from its stack frame after setting only the high word, so
    the tile attribute is whatever an earlier interrupt frame left at `-2(a6)`. In the
    L2p run 160 background attribute words differ for several thousand frames (`$0003` in the
    original, `$0002` converted); every rendered pixel is identical (the tiles are blank). On the original
    hardware this value depends on the same interrupt timing.

## 68000/Z80 phase

The sound CPU sees the same values, in the same order, from both sets, but not always at
the same cycle, and it amplifies small differences into occasional long handshake stalls
(below). Two sources of such 68000 timing offsets are now handled; measured on the
two-player max-load session (MAME, interrupted PC of every vblank interrupt over 52,000
frames; cycle-stamped 68000 traces aligned instruction by instruction):

* **The idle hook** used to burn 724 + (up to 330) cycles before handing back to the
  game's polling loop; a vblank or scanline interrupt arriving in that window landed
  differently, and the offset persisted. hle_idle now jumps into the original loop at
  the instruction the original is executing at that moment (any of 16 boundaries of the
  330-cycle pass, stubs that set up the loop's state, including the callback's stack
  frame; table by DEBT mod 330, kept in DPH when DEBT changes). It models the original's
  first pass after entry: the callback index is usually 0 then (the pass skips its clear,
  26 cycles shorter), and when the callback has a vblank to catch up on it takes its long
  path (84 cycles longer; the hook performs its two RAM updates). Window: 380 + pad + setup
  cycles instead of 910 + D; the once-a-minute clock read (countdown 0) and other callback
  sets use the old way.
* **Interrupts during a send() wait.** The replacement's wait is laid out in 94-cycle
  passes that start exactly at the original's latch reads; a sentinel word below the
  stack pointer, armed where the original posts the latch, shows afterwards whether an
  interrupt was taken, its stacked PC (and the saved loop counter) when, and the handler's
  first return address which one. irq_saved (job.s) computes the polls the original saved;
  the difference (and the cost of the check) goes into DEBT and is repaid at the idle
  loop. A residual remains: the interrupt lands on a different instruction than in the
  original, and the acknowledge is synchronised to the 10-cycle E clock, so 10-20 cycles
  can remain (seen at frame 990 of the session).

Result: the vblank interrupt lands on the same instruction in both sets in 31% of frames
(before: 23%); in-step stretches are longer. The remaining offsets come from the residual
above, the scanline-0 interrupt arriving during the (shorter) idle-hook window, ARM poll
mispredictions, and the Z80 handshake itself once the Z80s differ. In the sessions run, the
two-player max-load game now diverges at logical frame 58,150 (before: 51,157), the
two-player no-cheat game still at 9,642 (a stall in the original's own Z80 timing, which
the original does not reproduce either with its Z80 detuned by 30 ppm).

Side effect: the sentinel ($FFFF) is written into dead stack below the stack pointer,
where the original leaves older data. Game code that reads uninitialised stack (as the
blank-tile attribute bug does) can copy it: two RAM bytes in one logical frame of the
one-player no-cheat game (`$80004A`, `$80F036`, `$FF` instead of `$00`), with one video
frame's sprite buffer; no pixel differs. Restoring the word would need cycles the send
prologue does not have (it must be armed by +44).

Cost: the cmd 14 job path computes DEBT mod 330 (580 cycles, counted in the debt): every
margin above is about 590 cycles smaller (tightest: 11,213 cycles, one-player final boss).
