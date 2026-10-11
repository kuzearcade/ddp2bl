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

## Full game, start to ending (`harness/fullgame.sh`)

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
