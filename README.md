# ddp2bl — DoDonPachi II without the IGS027A

Converts a `ddp2` (World, v102) MAME set into `ddp2bl`: the program ROM answers every
IGS027A request in 68000 code, so the game runs on a plain PGM cartridge with no ASIC,
no external ARM ROM and no cartridge RAM. It is meant to bring cartridges with a dead
IGS027A back to life.

The conversion is checked against the protected set in MAME, frame by frame, over full
games (see `docs/verification.md`).

No ROM data is stored here; everything is derived from your own dumps.

## Building ddp2bl.zip (end users)

Needs only Python 3 (standard library). The 68000 replacement code is committed as
`hle/build/ddp2_v102_world.bin`, so no assembler is needed.

```
python3 tools/ddp2bl_build.py ddp2.zip -o ddp2bl.zip
```

`ddp2.zip` must be the MAME set for *DoDonPachi II - Bee Storm (World, ver. 102)*. Every
input file is checked against known hashes (the program by SHA1, before it is patched),
and the tool prints the region and the CRC32/SHA1 of each output file.

To also write the EPROM images (all 27C322) for a cartridge:

```
python3 tools/ddp2bl_build.py ddp2.zip -o ddp2bl.zip --images ddp2bl_images/
```

`docs/hardware.md` describes the images and how they relate to the original
cartridge.

### Region

The region is the one the IGS027A reports, so by default the build keeps the source
set's: World. To build another region, pass `--region` with `china`, `taiwan`, `japan`,
`korea`, `hongkong` or `world`:

```
python3 tools/ddp2bl_build.py ddp2.zip -o ddp2bl.zip --region japan
```

MAME's regional `ddp2` sets pair this same v102 program with another region's IGS027A,
and the game takes its region from the code that chip reports. Only that code changes,
one byte of the program. Checked for Japan in MAME: the game shows the Japan warning and
the Cave licence screen. The other regions' ARM ROMs weren't available to compare against. Its checksums then differ from the
World build listed in the MAME driver and the MiSTer MRA, so MAME warns about a wrong
checksum (the game still runs).

### MiSTer

Copy `ddp2bl.zip` next to `pgm.zip` (usually `/media/fat/games/mame/`) and
`mister/DoDonPachi II - Bee Storm (World, ver. 102, no IGS027A).mra` to `/media/fat/_Arcade/`.
The MRA uses the IGSPGM core with game id 00 (a board without the ARM).

### MAME

Stock MAME has no `ddp2bl` driver. To run it, build MAME with `mame/ddp2bl.patch`
(see below).

## Developer build

The commands below assume the layout used during development:

| Path | Content |
|---|---|
| `~/DDP2_Repair/ddp2bl` | this repository |
| `~/DDP2_Repair/toolchain` | assembler, Musashi, Python venv (user-space, no root needed) |
| `~/DDP2_Repair/mame-ddp2bl` | MAME tree with `mame/ddp2bl.patch` applied |

Other locations work by overriding the paths:
* `make TOOLS=... PROG=...` for the build;
* `make -C harness/m68k MUSASHI=...` for the bench;
* `--mame` and `--rompath` for `harness/run.py`.

### 1. Toolchain

* **vasm** (68000, Motorola syntax). Build it from source (http://sun.hasenbraten.de/vasm/)
  and put the binary in `toolchain/bin/vasmm68k_mot`:
  ```
  cd ~/DDP2_Repair/toolchain/src
  tar xf vasm.tar.gz && cd vasm && make CPU=m68k SYNTAX=mot
  cp vasmm68k_mot ~/DDP2_Repair/toolchain/bin/
  ```
* **Musashi** (the cycle-counting 68000 bench):
  ```
  git clone https://github.com/kstenerud/Musashi ~/DDP2_Repair/toolchain/src/Musashi
  ```
* **Python venv** with `unicorn` (ARM reference, fuzzer), `capstone` and `numpy` (audio check):
  ```
  python3 -m venv ~/DDP2_Repair/toolchain/venv
  ~/DDP2_Repair/toolchain/venv/bin/pip install unicorn capstone numpy
  ```
* **gcc** for the C model and the bench.
* Optional, for analysis only: binutils for `m68k-elf` / `arm-none-eabi`, and Ghidra
  (`tools/ghidra/`).

### 2. MAME

`mame/ddp2bl.patch` applies to mamedev master `017b8670f0a`. It adds:
* the ASIC-less `ddp2bl` driver;
* IGS027A protocol capture (`DDP2_CAPTURE`);
* the per-instruction CPU interleave (`DDP2_PERFECT`);
* the cycle probe (`DDP2BL_PROBE`);
* the Z80 clock detune (`DDP2_Z80_PPM`);
* Lua `share:read_raw`, which reads shared RAM without a Z80 sync.

```
git clone https://github.com/mamedev/mame.git ~/DDP2_Repair/mame-ddp2bl
cd ~/DDP2_Repair/mame-ddp2bl
git checkout -b ddp2bl 017b8670f0a
git apply ~/DDP2_Repair/ddp2bl/mame/ddp2bl.patch
make SUBTARGET=pgm SOURCES=src/mame/igs/pgm.cpp SYMBOLS=1 OPTIMIZE=3 TOOLS=0 -j$(nproc)
```

This produces `~/DDP2_Repair/mame-ddp2bl/pgm`. Build with `TOOLS=1` if you also want
`unidasm` (step 3).

After changing the P1 code, rebuild MAME:
1. Put the builder's new P1 `CRC`/`SHA1` in the `ddp2bl` entry of `src/mame/igs/pgm.cpp`.
2. Rebuild.
3. Refresh the patch: `git diff 017b8670f0a > ~/DDP2_Repair/ddp2bl/mame/ddp2bl.patch`.

If you edit `arm7.h`, delete the stale arm7 objects first. make does not rebuild them,
and MAME crashes.

The harness ROM path `work/roms/` must hold `pgm.zip`, `ddp2.zip` and the built `ddp2bl.zip`.

### 3. Inputs derived from the dumps (`work/`, not committed)

* `work/prog/v102.be.bin`: `v102.u8` from `ddp2.zip`, byte-swapped to 68000 (big-endian) order.
* `work/prog/v102.dasm`: its disassembly, made with MAME's `unidasm`.
* `work/arm/internal.bin`: the IGS027A's internal ROM, which is `ddp2_igs027a_world.bin`
  from `ddp2.zip` (used by the test tools; the build itself reads it from `ddp2.zip`).

To create all three:

```
mkdir -p work/arm work/prog
python3 -c 'import zipfile; z = zipfile.ZipFile("work/roms/ddp2.zip")
open("work/arm/internal.bin", "wb").write(z.read("ddp2_igs027a_world.bin"))
d = z.read("v102.u8"); o = bytearray(len(d)); o[0::2] = d[1::2]; o[1::2] = d[0::2]
open("work/prog/v102.be.bin", "wb").write(o)'
unidasm -arch m68000 -basepc 100000 work/prog/v102.be.bin > work/prog/v102.dasm
```

The analysis tools (`tools/armref.py`, `harness/fuzz.py`) also need
`work/arm/external_dec.bin` and `xortab.bin`. These are the decrypted external ARM ROM
and the XOR table, read from the protected set's `:prot` address space in MAME
(`0x08000000`, 128 KB, and `0x50000000`, 1 KB) once it has booted.

### 4. Build the replacement code and the patch list

```
make                          # hle/build/ddp2_v102_world.{bin,lst,inc}, targets/ddp2_v102_world/patches.json
make oracle/libestmodel.so    # C model of the ARM firmware
make -C harness/m68k          # Musashi bench (harness/m68k/libm68r.so)
python3 tools/ddp2bl_build.py work/roms/ddp2.zip -o work/roms/ddp2bl.zip
```

`make` runs three steps:
1. `tools/cycacc.py` generates the cycle-accounted job code.
2. vasm assembles `hle/hle.s`.
3. `tools/gen_patches.py` checks every patch site against the original program.

Commit `hle/build/*.bin` and `patches.json` so end users can build without the toolchain.

## Verification

Run the scripts with the venv Python (`~/DDP2_Repair/toolchain/venv/bin/python3`). Some
need `unicorn` or `numpy`.

| Check | Command |
|---|---|
| Capture the ARM protocol on the protected set | `harness/run.py --machine ddp2 --mode bot --capture --perfect --frames N --out DIR` |
| Every command vs the C model (68000 bench) | `harness/hle_test.py DIR` |
| Whole command stream with carried state and send timing | `harness/hle_stream_test.py DIR` |
| Real ARM firmware vs model vs 68000, random requests | `harness/fuzz.py DIR` |
| Timing margin of every frame | `harness/hle_stream_test.py DIR --jobs-out DIR/jobs.txt`, then `tools/margin.py DIR` |
| Full game, protected vs converted, frame by frame | `sh harness/fullgame.sh 1p\|2p\|nc1p\|nc2p work/runs/NAME` |
| Sound packets and output of a full game | `AUDIO=1 sh harness/fullgame.sh ...`, then `tools/audiocheck.py work/runs/NAME_ref work/runs/NAME_bl` |

`fullgame.sh` replays the recorded inputs in `harness/inputs/` on both sets with
per-cycle interleave. `harness/compare_runs.py` then compares, frame by frame:
* video RAM, palette and pixels;
* game-logic RAM;
* sound commands;
* frame pacing.

MAME ignores SIGTERM/SIGINT under the harness, so stop it with `kill -9 <pid>`. Never use
`pkill -f` with a pattern that also matches your own shell's command line.

## Layout

* `targets/<name>/`: per game/version/region description (hashes, addresses, RAM map,
  patches). New versions are added here.
* `hle/`: 68000 replacement code:
  * `hle.s`: send/idle hooks;
  * `job.s`: bullet job;
  * `est_*.s`: EST engine.

  `hle/build/` holds the committed binary.
* `tools/`: the builder (`ddp2bl_build.py`) and:
  * patch and include generators;
  * cycle accounting;
  * capture reader and Unicorn ARM reference;
  * timing, margin and audio analysis;
  * MAME Lua scripts.
* `oracle/`: C model of the ARM firmware, verified against the real firmware.
* `harness/`: MAME harness (`run.py` and Lua), Musashi bench, tests, recorded inputs.
* `mame/`: MAME patch (`ddp2bl` driver and analysis instrumentation).
* `mister/`: MiSTer MRA.
* `cfg/`: MAME configs for `ddp2` and `ddp2bl`.
* `docs/`:
  * `protocol.md`: IGS027A commands;
  * `timing.md`: cycle model;
  * `hardware.md`: cartridge build;
  * `verification.md`: results.

## Legal

This repository contains no original game code or data. It includes no ROM images,
program bytes, ARM firmware, disassembly or decompiled code of the game or of the
IGS027A, and no game graphics or sound. Everything here is original work:
* the 68000 replacement code;
* the tools;
* the documentation, which describes the hardware's behaviour by address and function.

The original program is checked only by its hash. The builder needs a dump you supply
(`ddp2.zip`) and produces the converted set from it locally.

The project is intended strictly for repairing original *DoDonPachi II* cartridges
whose IGS027A has failed, so that the owner of the original board can keep using it.
It is not intended for making copies of the game or for any other use.

*DoDonPachi* and the game's assets belong to their respective rights holders. This
project is not affiliated with or endorsed by Cave or IGS.
