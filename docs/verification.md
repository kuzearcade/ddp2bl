# Verification

Everything below is reproducible with the tools in this repository and the MAME branch
`ddp2bl` (PGM-only build).

## 1. The ARM firmware, understood exactly

| Step | Tool | Result |
|---|---|---|
| Unicorn model of the real firmware vs MAME captures | `tools/validate_armref.py` | 91,662 / 91,662 commands identical (shared RAM + ARM RAM) |
| Readable C model vs MAME captures | `oracle/test_model.py` | 6.2 M commands over 11 captures, all identical |
| Model coverage | gcov | every reachable path except script opcodes 1 and $11 (absent from all scripts) |

## 2. The 68000 replacement, functionally

| Step | Tool | Result |
|---|---|---|
| Per command vs C model (Musashi 68000) | `harness/hle_test.py` | 6.2 M commands identical |
| Carried state, whole command stream | `harness/hle_stream_test.py` | all windows and engine states identical |
| Differential fuzzing: real firmware vs model vs 68000 | `harness/fuzz.py` | 260k+ commands, random spawns of every type/script (incl. scripts only used late in the game), zero mismatches (re-run on the final build: 24,000 commands, 0) |
| Final build, per command vs model, three 60,000-frame captures | `harness/hle_test.py` | 871,307 commands identical (+1,514 cmd 14 "busy" answers, captured mid-job) |
| Final build, whole command stream incl. timing-visible state | `harness/hle_stream_test.py` | shared window identical after every one of 871,163 commands |
| Game's own IGS027 self-test (27 INTERNAL/SHARE/SYSTEM RAM TEST) | 68000 bench, patched program + BIOS | passes |

## 3. The converted game in MAME vs the protected game

Both machines run the same recorded inputs (bot: aiming, many credits; with and without
invulnerability/lives cheats) with per-cycle interleave and a fixed RTC; fresh NVRAM.

Compared every video frame (`harness/compare_runs.py`):
* VRAM, palette RAM, video registers, rendered pixels;
* main RAM (canonical: relocated shared window folded back; replacement-private state and dead
  stack below SP masked; the 46 pointer words the game keeps into the shared window compared
  by target) and Z80 RAM.

Compared every **logical frame** (sampled when the game itself starts a frame):
* the whole main RAM (canonical as above), and "game-logic RAM": the same minus three
  bookkeeping records that depend on sub-frame timing (`target.json` `bookkeeping_masks`,
  docs/timing.md "Residual differences"): the once-a-minute clock poll state
  (`$80EE40-$80EE57`), the BIOS running-time record it updates (`$8021E2-$8021ED`), and
  send()'s poll counter residue (`$80ECAE-$80ECB1`);
* the exact sequence of sound commands sent to the Z80 during that frame,
* the video frame in which each logical frame starts (slowdown/lag pattern).

Cycle-level checks with the MAME probe: the job's run-time cycle accounting against MAME's
68000 core, and the idle-loop phase lock (docs/timing.md).

## Results (final build, `harness/longruns.sh`)

Three recorded input sessions, 60,000 video frames each (16.7 minutes of play), protected
set vs converted set, both with per-cycle interleave:

| run | inputs | pixels | palette | video regs | VRAM | game-logic RAM (logical frames) | sound commands | lag pattern |
|---|---|---|---|---|---|---|---|---|
| L1p | 1 player, aiming bot, lives + invulnerability cheats | 0 / 60001 differ | 0 | 0 | 0 | 0 / 59374 | 0 | 0 |
| L2p | 2 players, cheats for both | 0 / 60001 | 0 | 0 | 16,038 frames (see below) | 0 / 59374 | 0 | 0 |
| Lnc | no cheats, credits | 0 / 60001 | 0 | 0 | 0 | 31 / 59364 (stale stack, see below) | 0 | 0 |

"Lag pattern": the video frame in which the game starts each of its logical frames, i.e.
slowdown is identical frame for frame.

Differences that remain, all explained (docs/timing.md):
* main RAM sampled at the video frame boundary and Z80 RAM: the 68000's timeline inside a
  frame (between cmd 14 and the vblank wait) is shifted by the bullet job, so these are
  sampled at a different point of the same work;
* the three bookkeeping records above (game-logic RAM masks just them);
* Lnc, logical frames 50,922-50,952: 18 bytes at `$81FF60-$81FF7F`, leftover data near the
  top of the stack that no code has written since (the same values in both sets, displaced
  by 8 bytes: an interrupt frame taken at a different depth); the game overwrites them
  identically 31 frames later. Seen with the current build only, whose shorter job changes
  the idle-loop phase (the previous build had a different phase there and 0 such frames);
* L2p VRAM: 160 background tile attribute words written from an uninitialised local
  (game bug at `$13F4C6`, value comes from an earlier interrupt's stack frame); the tiles
  are blank, every rendered pixel is identical.

Timing margin of the conversion over all gameplay frames of the three sessions: at least
38,355 cycles (worst debt/slack 0.77), docs/timing.md.

Job cycle accounting in MAME: measured - accounted constant (38 cycles of probe overhead)
for every job not hit by an interrupt.

## Full game, start to ending, one player (`harness/fullgame.sh 1p`)

One player plays the whole game: the aiming bot with lives and invulnerability cheats,
recorded on the protected set (`harness/inputs/fullgame_1p.txt.gz`), 145,900 video frames
(40.5 minutes): all stages, the final boss (from ~frame 90,800, mostly in slowdown), its
defeat (~108,300), the ending ("THE END" ~109,800), the high-score entry (1st place,
664,852,000) and the start of a new game. Both sets replayed with per-cycle interleave.

| check | result |
|---|---|
| rendered pixels, VRAM, palette, video registers | identical in all 145,901 video frames |
| sound commands per logical frame | identical (145,250 logical frames) |
| lag pattern (video frame of each logical frame) | identical |
| game-logic RAM per logical frame | identical up to logical frame 107,543; afterwards 2 bytes differ (below) |
| screenshots (every 1,000 frames, every 100 around the ending) | 245 of 245 identical |
| protocol stream vs the 68000 replacement (`hle_stream_test.py`) | 701,137 of 701,139 shared-window states identical (the 2: the busy answer below) |
| job cycle accounting in MAME (probe) | measured - accounted = 38 for all 137,540 jobs no interrupt hit |
| timing margin (`margin.py`) | 0 late frames; worst 11,801 cycles (debt/slack 0.91) |

The protected set itself replays deterministically (bot run and two replays identical).

**The one difference: an ARM "busy" answer.** When the final boss dies (video frame
108,173) 115 bullets turn into debris at once. That ARM job took 31,434 cycles, the game
asked for the results after 26,712: the ARM answered "not done", the game waited and sent
cmd 14 again. Each `send()` advances the protocol sequence byte, so from then on
`$808C9C/$808C9D` (sequence number and its echo) are one step apart between the two sets
(the converted set answers at once). Only the protocol code uses them (`send()` and its
variants number each command with it and compare the ARM's echo; the boot check resets it to
`$80`), so the game is otherwise identical; every pixel and sound
command of the ending, the name entry and the next game matches. Over the whole capture it
is the only busy answer outside the post-cmd-13 case (1 of 138,483 cmd 14). Reproducing it
would need the 68000 to know the time between cmd 12 and cmd 14 (it has no timer; the
scanline counter at `$B07000` is 1,280 cycles coarse) and a cycle model of the ARM job;
many frames have the ARM finish only 900-2,000 cycles before cmd 14 (docs/timing.md).

**Found and fixed by this test.** The first full-game run (previous build) diverged at
logical frame 90,204, the final boss: the original is in slowdown there and the bullet job
(126 bullets, 139,406 cycles) overran the time left before the vblank by 5,317 cycles, so
the game dropped one update; the pictures differed from then on (same stages, different
scores). The job was made faster (state-2 bullet fast path, packer dispatch, update loop
counter, free-slot search; outputs unchanged): 122,288 cycles on that frame.

## Full game, two players at maximum load (`harness/fullgame.sh 2p`)

Two players, both firing the shot on autofire for the whole game and dropping a bomb
whenever one is in stock (bot style `max`, different seed and inputs from every other
session; lives held at the starting count and invulnerability for both,
`harness/inputs/fullgame_2p.txt.gz`). 81,200 video frames: all stages, the last boss
(defeated ~74,200), the ending (~74,800-75,400), name entry for both players and the start
of a new game.

| check | result |
|---|---|
| rendered pixels, palette, video registers | identical in all 81,201 video frames |
| screenshots (every 1,000 frames) | 82 of 82 identical |
| VRAM | 4,096 frames differ: the known blank-tile attribute words (game bug at `$13F4C6`, values 6/7), no pixel differs |
| sound commands | identical; in 16 logical frames only the number of Z80 handshake polls differs (below) |
| lag pattern | identical except 4 logical frames whose start moves across MAME's frame-number change (below) |
| game-logic RAM | identical except 62 logical frames: 3-5 bytes of stale stack at `$81FF7C-$81FF85` (frames 55-85 and 75,147-75,177) |
| protocol stream vs the 68000 replacement | 384,999 of 385,000 shared-window states identical (the last command is cut off by the end of the capture); no ARM busy answer |
| job cycle accounting in MAME (probe) | measured - accounted = 38 for all 77,527 jobs no interrupt hit |
| timing margin | 0 late frames; worst 18,391 cycles (debt/slack 0.88) |

**Z80 handshake.** Before some sound commands the game waits for the sound CPU: it writes
`$F1` to the third latch and reads the Z80's answer until it is ready (`$175976-$1759AE`).
How long that takes depends on what the Z80 is doing at that moment, and the Z80 gets the
frame's later sound commands a few thousand cycles later in the converted set (docs/timing.md),
so these waits differ: from 1 poll to 371 (about 56,000 cycles) in the frames listed. The real sound
commands are the same, in the same order and the same logical frames. When such a wait
moves the start of a logical frame past scanline 0 (where MAME's frame number changes,
~51,000 cycles after the vblank interrupt), the harness records the start one video frame
later; in all 4 cases the next logical frame starts in the same video frame in both sets and
no displayed frame differs.

**Cheat fix found by this test.** The first attempt stopped at frame ~33,900 in the
*original* set with the game's own assertion `cplayer.c 250: p->cntLife <= RV_DEBUTLIFE`:
player 2 collected an extend while the lives cheat held 3 lives, then died. Player 2 could
die because `invuln_p2` used a wrong object offset (`0x114`; player 2's object is `0x192`
after player 1's), so it wrote into an unrelated field of player 2's object every frame
and did not protect player 2. New cheats `lives3_p1/p2` (lives held at the starting count
`$803808`) and `invuln2_p2` fix this; the old ones are kept unchanged so that the earlier
sessions replay exactly (the L2p session above ran both sets with the wrong address, which is
a valid comparison but did not make player 2 invulnerable).

## Full games without cheats, continuing to the ending (`harness/fullgame.sh nc1p|nc2p`)

The bot continues after every game over (coins every 300 frames; while a player has no
lives left it presses only start, so the continue countdown is never shortened by the
fire buttons).

**One player** (`nc1p`, aiming bot, 106,000 frames, all stages with continues, the ending
"THE END ..?" ~101,000, name entry 160,672,349, a new game):

| check | result |
|---|---|
| pixels, VRAM, palette, video registers | identical in all 106,001 frames |
| game-logic RAM, sound commands, lag pattern | identical (105,361 logical frames) |
| screenshots | 107 of 107 identical |
| protocol stream vs the replacement | 499,999 of 500,000 (last command cut off) |
| job accounting in MAME | 38 for all 93,322 jobs no interrupt hit |
| timing margin | 0 late frames, worst 24,865 cycles |

**Two players** (`nc2p`, autofire + bombs, 89,000 frames, ending ~76,000): identical up to
logical frame 9,641, then the games differ (both still reach the ending). Protocol stream
419,999 of 420,000 identical; job accounting exact.

Cause: at video frame 10,264 the vblank handler's Z80 handshake (`$175976`: `$F1` to latch 3,
poll `$C00004` until the Z80 is ready) found the protected set's Z80 busy for ~217,000
cycles, the converted set's Z80 not at all. That delayed the original's frame start by
two thirds of a frame, so two logical frames started within one video frame and the
per-frame inputs (read in the vblank handler, identical in both) were consumed in a
different pattern; with the autofire bot that changed when a shot was fired. The Z80's
state had drifted apart long before (Z80 RAM differs from frame ~740 in every run): the
vblank handler's latch writes land a few to a few dozen cycles differently when the
interrupt arrives in different instructions (slowdown frames, where the converted game's
post-cmd-14 code is shifted by the job; the idle-loop phase residuals), and the Z80
amplifies that.

**The protected set is not stable against this either.** The PGM's 68000 (20 MHz crystal)
and Z80 (33.8688 MHz crystal) are clocked independently, so a real board never reproduces
one exact 68000/Z80 phase. The protected set replayed with the Z80 clock off by +30 or -30
ppm (normal crystal tolerance; MAME `DDP2_Z80_PPM`, 30,000 frames):

| comparison | first differing logical frame |
|---|---|
| original vs original, Z80 0 ppm (control) | none |
| original vs original, Z80 +30 ppm | 9,642 (the same stall) |
| original vs original, Z80 -30 ppm | 9,642 |
| converted vs original +30 ppm | ~25,368 |
| converted vs original -30 ppm | ~12,380 |

So this divergence is a property of the game's 68000/Z80 handshake at one exact clock
phase, not something the conversion can or should reproduce: an original board would not
reproduce it from one power-on to the next.
