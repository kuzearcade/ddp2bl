#!/bin/sh
# Full games, start to ending: the protected set and the converted set replay the same
# recorded inputs (per-cycle interleave) and are compared frame by frame.
#   harness/fullgame.sh [1p|2p|nc1p|nc2p] <out_prefix> [rompath for ddp2bl]
#   1p: one player, aiming bot, lives + invulnerability cheats; 145,900 frames: all stages,
#       the extra final stage and its boss (~90,800-108,300), the ending ("THE END"
#       ~109,800), name entry and a new game.
#   2p: two players, shot on autofire for both all game and a bomb whenever one is in stock
#       (bot style "max", maximum screen load); 81,200 frames: ending at ~74,800, name
#       entry, a new game.
#   nc1p: one player, no cheats, continuing after every game over (bot "aim", continue
#       mode); 106,000 frames: ending "THE END ..?" ~101,000, name entry, a new game.
#   nc2p: two players, no cheats, continuing (bot "max"); 89,000 frames: ending ~76,000.
#       Diverges at logical frame 9,642 through a Z80 handshake stall (docs/verification.md).
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
nc1p) F=106000; C="" ;;
nc2p) F=89000;  C="" ;;
*)  echo "session: 1p, 2p, nc1p or nc2p"; exit 1 ;;
esac
mkdir -p "$(dirname "$P")"
gzip -dc harness/inputs/fullgame_$S.txt.gz > ${P}_inputs.txt
L=$(pwd)/tools/lua
mkdir -p ${P}_ref ${P}_bl
# both runs: vblank/idle log (slack.txt) and the sound path monitor (sound.txt,
# tools/lua/sndmon.lua); AUDIO=1 also records the sound output (audio.wav, for
# tools/audiocheck.py)
wav() { [ -n "$AUDIO" ] && echo "-wavwrite $1/audio.wav"; }
EXTRA_LUAS="$L/slack.lua;$L/sndmon.lua" DDP2H_EXTRA_LUA=$L/multi.lua \
SLACK_OUT=${P}_ref/slack.txt SNDMON_OUT=${P}_ref/sound.txt \
python3 harness/run.py --machine ddp2 --mode replay --inputs ${P}_inputs.txt --cheats "$C" --frames $F --perfect \
    --capture --extra "$(wav ${P}_ref)" --out ${P}_ref > /dev/null 2>&1 &
EXTRA_LUAS="$L/slack.lua;$L/sndmon.lua" DDP2H_EXTRA_LUA=$L/multi.lua \
SLACK_OUT=${P}_bl/slack.txt SNDMON_OUT=${P}_bl/sound.txt \
python3 harness/run.py --machine ddp2bl --rompath "$R" --mode replay --inputs ${P}_inputs.txt --cheats "$C" --frames $F \
    --perfect --ptrlocs harness/inputs/fullgame_$S.ptrlocs --extra "$(wav ${P}_bl)" --out ${P}_bl > /dev/null 2>&1 &
wait
python3 harness/compare_runs.py ${P}_ref ${P}_bl | tee ${P}.cmp | cut -c1-300
