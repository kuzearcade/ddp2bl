#!/bin/sh
# Full games, start to ending: the protected set and the converted set replay the same
# recorded inputs (per-cycle interleave) and are compared frame by frame.
#   harness/fullgame.sh [1p|2p] <out_prefix> [rompath for ddp2bl]
#   1p: one player, aiming bot, lives + invulnerability cheats; 145,900 frames: all stages,
#       the extra final stage and its boss (~90,800-108,300), the ending ("THE END"
#       ~109,800), name entry and a new game.
#   2p: two players, shot on autofire for both all game and a bomb whenever one is in stock
#       (bot style "max", maximum screen load); 81,200 frames: ending at ~74,800, name
#       entry, a new game.
# Also writes the protected set's protocol capture and vblank/idle log (<out>_ref), from
# which tools/margin.py computes the timing margin of every frame:
#   python3 harness/hle_stream_test.py <out>_ref --jobs-out <out>_ref/jobs.txt
#   python3 tools/margin.py <out>_ref
set -e
S=${1:-1p}
P=${2:-work/runs/FG_$S}
R=${3:-work/roms}
case $S in
1p) F=145900; C=lives_p1,invuln_p1 ;;
2p) F=81200;  C=lives3_p1,lives3_p2,invuln_p1,invuln2_p2 ;;
*)  echo "session: 1p or 2p"; exit 1 ;;
esac
mkdir -p "$(dirname "$P")"
gzip -dc harness/inputs/fullgame_$S.txt.gz > ${P}_inputs.txt
L=$(pwd)/tools/lua
mkdir -p ${P}_ref
DDP2H_EXTRA_LUA=$L/slack.lua SLACK_OUT=${P}_ref/slack.txt \
python3 harness/run.py --machine ddp2 --mode replay --inputs ${P}_inputs.txt --cheats $C --frames $F --perfect \
    --capture --out ${P}_ref > /dev/null 2>&1 &
python3 harness/run.py --machine ddp2bl --rompath "$R" --mode replay --inputs ${P}_inputs.txt --cheats $C --frames $F \
    --perfect --ptrlocs harness/inputs/fullgame_$S.ptrlocs --out ${P}_bl > /dev/null 2>&1 &
wait
python3 harness/compare_runs.py ${P}_ref ${P}_bl | tee ${P}.cmp | cut -c1-300
