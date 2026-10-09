# DDP2 (v102 World) ↔ IGS027A protocol

Findings from static analysis (Ghidra, `tools/ghidra/DDP2Setup.java`) and MAME traces.
Addresses: 68k unless prefixed `ARM`.

## Memory views

| 68k | ARM | Notes |
|---|---|---|
| `$D00000-$D0FFFF` | `$48000000-$4800FFFF` | shared RAM. 68k word at `$D00000+n` = ARM halfword at `+n` (little endian in ARM memory). A 68k long at `+n` is `(hw[n] << 16) \| hw[n+2]`. |
| `$D10000-$D10001` | `$38000000` | latch. 68k writes sequence byte (low byte); ARM writes busy (`$80`), error codes, or the echoed sequence. |
| — | `$18000000-$1800FFFF` | ARM work RAM (64K, only ~`$3300` used) |
| — | `$10000000-$100003FF` | ARM internal RAM |
| — | `$00000000-$00003FFF` | internal ROM (vectors, EST engine, sin/cos table at `$2890`) |
| — | `$08000000-$0801FFFF` | external ROM `v100_210.u23` (XOR-decrypted by `pgm_ddp2_decrypt` + uploaded table): handler code at `$08010000+`, data tables (bullet scripts) below |

## Handshake (68k `$145918`, `send(cmd)`)

1. write the command word to `$D00010`
2. write the sequence byte (at `$808C9C`) to the latch `$D10001`, then `seq = (seq+1) & $7F`
3. `$80ECAE = 10000`; loop: `$80ECAE -= 1` (timeout → error), `$808C9D = latch`, until `latch == seq`
4. `$80ECAA = $D00010` (status, 0 = OK); nonzero prints an error.

Boot check at `$145A0A`: waits for latch `$80`/`$81`, sets seq `$80`, then sends cmd 1.

ARM FIQ handler (`$08010488`): latch ← `$80` (busy), checks seq, dispatches `table[$08011C90][cmd]` (cmd ≤ `$17`, else hang with `$88`), then clears `$48000010` and latch ← next expected seq.

## Commands

| cmd | handler | effect |
|---|---|---|
| 01 | `$08010928` | system init flags (`ARM $18002F90`) |
| 02 | `$08010978` | set flag `ARM $18002F9E` |
| 03 | `$08010BD8` | `$D00020 ← (flag == 0)` |
| 04 | `$08010A84` | drain message queue (64-byte entries, ring `ARM $1800328C..+$200`) to `$D002A0+`, count → `$D00020` |
| 09 | `$08010018` | `ARM $18002FA4[0..7] ← $D00020[0..7]` (EST globals; word 7 = Y offset added to bullets) |
| 0A | `$0801002C` | `ARM $18002FAC[0..7] ← $D00020[0..7]` |
| 11 | `$2594` | EST reset: clear all object states, clear EST system vars |
| 12 | `$25D4` | EST start (mode A): copy header `$D01F00` (24 bytes) and `count*24` bytes from `$D01F80` into ARM, schedule background job `$55C` |
| 13 | `$2698` | EST start (mode B): as 12 without latching count into `+$1A`; job `$1730` |
| 14 | `$274C` | EST collect: if job done → `$2340` copies results to shared RAM, `$D00020 ← 1`; else `$D00020 ← 0` |
| 15/16/17 | `$08010CC8/$08010C80/$08010CA4` | non-destructive RAM tests (IRAM / shared / work RAM); `$D00022 ← (fail)` |
| others | `$08010BAE` | "UNUSED HRQCMD" log message |

68k side of cmd 14 (`$163D86`): `send(14)`; if `$D00020 != 1` → delay loop (`$400` iterations), retry.
Results: hit count `$D01F18`, hit list `$D01F1C+`, object blocks at `$D005E0`, `$D007E0`, `$D00880`,
`$D00EC0`, `$D01500`, `$D03000`.

## EST engine (bullet script interpreter, ARM `$55C`)

* Object pool: 127 × `$44` bytes at `ARM $18000090` (state word 0: 0 = free, 1..7).
* Per object: script pointer (`+$38`), angle byte (`+$18`), speed (`+$1A`), velocity (`+$10/+$12`),
  sub-pixel accumulators (`+$14/+$16`), position (`+$06/+$08`).
* Opcode switch on script word `+2`; trig from table `$2890` (256 × {cos, sin} s16);
  products rounded toward zero via `+$FF` before `>> 8`.
* RNG (`$08010CD8`): additive lagged Fibonacci, 55 dwords at `ARM $18003020`, indices
  `$18003100/$18003104`, returns `sum & $7FFFFFFF`. Quirk: when the second index underflows in the
  same call, the first index is decremented without wrap (can reach −1); must be reproduced.
* Script / sub-table data in the external ROM (e.g. `$080085A0`, 8-byte entries).

## Timing implications

The EST job runs on the ARM *concurrently* with the 68k after cmd 12/13 returns; cmd 14 only
reports completion. The number of cmd 14 calls (each advances the sequence byte at `$808C9C`)
depends on ARM job duration vs. 68k progress. See `docs/timing.md` (measurements).
