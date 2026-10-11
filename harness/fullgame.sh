#!/bin/sh
# Full single-player game, start to ending: the protected set and the converted set replay
# the same recorded inputs (aiming bot, lives + invulnerability cheats for player 1;
# 145,900 video frames, per-cycle interleave) and are compared frame by frame.
# The run reaches the final boss (~frame 90,800), the ending ("THE END" ~109,800), the
# high-score entry and the start of a new game.
#   harness/fullgame.sh <out_prefix> [rompath for ddp2bl]
# Also writes the protected set's protocol capture and vblank/idle log (<out>_ref), from
# which tools/margin.py computes the timing margin of every frame:
#   python3 harness/hle_stream_test.py <out>_ref --jobs-out <out>_ref/jobs.txt
#   python3 tools/margin.py <out>_ref
set -e
P=${1:-work/runs/FG}
R=${2:-work/roms}
F=145900
C=lives_p1,invuln_p1
mkdir -p "$(dirname "$P")"
gzip -dc harness/inputs/fullgame_1p.txt.gz > ${P}_inputs.txt
L=$(pwd)/tools/lua
mkdir -p ${P}_ref
DDP2H_EXTRA_LUA=$L/slack.lua SLACK_OUT=${P}_ref/slack.txt \
python3 harness/run.py --machine ddp2 --mode replay --inputs ${P}_inputs.txt --cheats $C --frames $F --perfect \
    --capture --out ${P}_ref > /dev/null 2>&1 &
python3 harness/run.py --machine ddp2bl --rompath "$R" --mode replay --inputs ${P}_inputs.txt --cheats $C --frames $F \
    --perfect --ptrlocs harness/inputs/fullgame_1p.ptrlocs --out ${P}_bl > /dev/null 2>&1 &
wait
python3 harness/compare_runs.py ${P}_ref ${P}_bl | tee ${P}.cmp | cut -c1-300
