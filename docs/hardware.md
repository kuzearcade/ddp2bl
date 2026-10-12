# Building a ddp2bl cartridge

The converted program no longer needs the IGS027A, its external ARM ROM, or any RAM on
the cartridge: all state lives in the PGM motherboard's main RAM.

## Generate the images

```
python3 tools/ddp2bl_build.py ddp2.zip -o ddp2bl.zip --images ddp2bl_images/
```

`ddp2.zip` must be the MAME set for *DoDonPachi II - Bee Storm (World, ver. 102)*; every
file is checked against known hashes. The tool prints the CRC32/SHA1 of each output.
The region defaults to World; `--region` selects another (see the README).

## The images (27C322 size, 4MB each)

| File | Content |
|---|---|
| `ddp2bl_p1.27c322` | patched program in the first 2MB (MAME's byte order); the second 2MB is empty |
| `ddp2bl_t1.27c322`, `ddp2bl_t2.27c322` | tiles: first and second half of `pgm_t1300.u21` |
| `ddp2bl_a1..a4.27c322` | sprite colour: `pgm_a1300` halves, then `pgm_a1301` halves |
| `ddp2bl_b1.27c322`, `ddp2bl_b2.27c322` | sprite masks: `pgm_b1300` halves |
| `ddp2bl_m1.27c322` | samples: `pgm_m1300.u5` |

The program runs at 68000 address $100000, above the motherboard BIOS, as on the original
cartridge.

## On an original DDP2 cartridge with a dead IGS027A

Not verified on hardware. The program EPROM (`v102.u8`, 27C160) can be replaced by the
first 2MB of `ddp2bl_p1.27c322` (byte-swapped back to the original file's order: the
first 2MB of the P1 file *is* that order). Whether the original cartridge's PAL decoding
and data bus work with the ASIC removed or dead has to be checked on the board (the
68000 no longer accesses $D00000-$D1FFFF at all).

## Battery-backed RAM

PGM main RAM is battery backed; the converted game keeps its ARM-replacement state there
(at $818000-$81DCC1, an area the original game never uses; the deepest stack write
in a whole two-player game is $81FC36). Whatever a previous session
left there does not matter: the game's cold-reset entry (patched, same cycle count) resets
what a reset of the IGS027A resets (latch "ready", region word, protocol state), and the
game re-initialises the bullet engine itself with cmd 11 at start-up, as it did with the ASIC.

## Self-test

The game's own test menu ("RAM TEST": 27 INTERNAL / SHARE / SYSTEM RAM TEST) still runs
and passes against the replacement (checked on the 68000 bench with the patched program
and the BIOS). Its shared-RAM test now walks $818000-$81FFFF (the relocated window, our
state and the stack): it is non-destructive (each word is saved, tested with $55AA/$AA55
and restored) and runs with interrupts masked, so nothing is disturbed. The BIOS service
menu (HARDWARE TEST, RAM TEST etc.) does not use the ASIC and is unaffected (identical
screens in both sets).
