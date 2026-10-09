# ddp2bl — DoDonPachi II without the IGS027A

Converts a `ddp2` (World, v102) MAME set into `ddp2bl`, a program ROM that answers every
IGS027A request in 68000 code, to bring cartridges with a dead IGS027A back to life.

Layout:
* `targets/<name>/` — per game/version/region description (hashes, addresses, RAM map)
* `tools/` — analysis tools (capture reader, Unicorn ARM reference, Ghidra script) and the builder
* `hle/` — 68000 replacement code
* `harness/` — verification harness (MAME Lua + Python, Musashi 68000 bench)
* `mame/` — patch for the MAME `ddp2bl` driver and analysis instrumentation
* `docs/` — protocol, timing and verification reports

No ROM data is stored here; everything is derived from the user's own dumps.
