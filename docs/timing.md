# Timing measurements (feasibility gate)

Reference: protected `ddp2` in the ddp2bl MAME branch, speedups disabled (`DDP2_NOSPEEDUP`),
default scheduler quantum, bot run seed 1 with lives+invulnerability cheats, 20000 frames
(`work/runs/cap1`). Tools: `tools/capture.py summary`, `tools/timing.py`.

## Handshake

Every command — including cmd 14 — was answered on the **first poll**: 148 68k cycles from the
latch write to the echo, so `$80ECAE` (poll budget) always ends at 9999 and `$808C9D` holds the
echoed sequence. cmd 14 never answered "not done" (0 of 17931).

## Command mix per frame

| mix | frames |
|---|---|
| 04, 09, 0A, 12, 14 | 14880 |
| 04, 09, 0A, 14 | 1043 |
| 04, 09, 0A, 12×2, 14 | 1043 |
| 04 only | 868 |
| 04, 09 | 541 |

## EST (bullet) job cost on the ARM

17931 jobs: 5014 / 6720 / 18243 / 25088 ARM cycles (min / median / p99 / max).
Worst frame total: ~39400 ARM cycles (two jobs in one frame).

## 68k idle time

Frame = 337920 68k cycles. Idle (game waiting for vblank) per frame: p1 = 184800, median 241230.
In frames that run an EST job the minimum idle was ~164000 cycles; the highest
job/idle ratio was 0.20. 15 frames had no idle at all (boot/transition frames, no EST job).

## Interrupts

* IRQ6 (vblank start): frame tasks (`$14808A`). Lands in the idle loop whenever the frame's
  work finished in time.
* IRQ4 (scanline 0): `$147EAE`, only `bclr/bset #2,$80ECCF` + write `$B0E000` (ack). Atomic and
  state-neutral with respect to where it lands.

## Consequences for the 68000 replacement

* Frames with idle time: extra 68k cycles are invisible at frame boundaries as long as the
  replacement's added cost stays below that frame's idle time → EST port budget ≈ 4× ARM cycles
  in the worst observed frame (needs confirming on heavier late-game scenes / 2P).
* Frames without idle (slowdown): extra cycles can change the lag pattern. Cheap commands are
  padded to the original handshake cost; EST frames that lag must be measured specifically
  (longer and 2-player runs).
