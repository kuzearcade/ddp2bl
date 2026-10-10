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
| Lnc | no cheats, credits | 0 / 60001 | 0 | 0 | 0 | 0 / 59364 | 0 | 0 |

"Lag pattern": the video frame in which the game starts each of its logical frames, i.e.
slowdown is identical frame for frame.

Differences that remain, all explained (docs/timing.md):
* main RAM sampled at the video frame boundary and Z80 RAM: the 68000's timeline inside a
  frame (between cmd 14 and the vblank wait) is shifted by the bullet job, so these are
  sampled at a different point of the same work;
* the three bookkeeping records above (full canonical RAM differs only there: game-logic
  RAM, which masks just them, is identical in every logical frame);
* L2p VRAM: 160 background tile attribute words written from an uninitialised local
  (game bug at `$13F4C6`, value comes from an earlier interrupt's stack frame); the tiles
  are blank, every rendered pixel is identical.

Timing margin of the conversion over all gameplay frames of the three sessions: at least
34,487 cycles (worst debt/slack 0.79), docs/timing.md.

Job cycle accounting in MAME: measured - accounted constant (38 cycles of probe overhead)
for every job not hit by an interrupt.
