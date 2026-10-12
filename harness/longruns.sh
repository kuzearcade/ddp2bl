#!/bin/sh
# Full-length verification: the protected set and the converted set replay the same
# recorded inputs (60000 video frames each, per-cycle interleave) and are compared.
#   harness/longruns.sh <out_prefix> [rompath for ddp2bl]
# Inputs (harness/inputs/longrun_*.txt.gz):
#   L1p: one player, aiming bot, lives + invulnerability cheats
#   L2p: two players, cheats for both
#   Lnc: no cheats, credits
# FRAMES=<n> runs a shorter replay (e.g. a quick check of the setup).
set -e
P=${1:-work/runs/V}
R=${2:-work/roms}
F=${FRAMES:-60000}
mkdir -p "$(dirname "$P")"
run() {  # name cheats
    gzip -dc harness/inputs/longrun_$1.txt.gz > ${P}_$1_inputs.txt
    python3 harness/run.py --machine ddp2 --mode replay --inputs ${P}_$1_inputs.txt --cheats "$2" --frames $F --perfect \
        --out ${P}_$1_ref > /dev/null 2>&1
    python3 harness/run.py --machine ddp2bl --rompath "$R" --mode replay --inputs ${P}_$1_inputs.txt --cheats "$2" --frames $F \
        --perfect --ptrlocs ${P}_$1_ref/ptrlocs.txt --out ${P}_$1_bl > /dev/null 2>&1
    python3 harness/compare_runs.py ${P}_$1_ref ${P}_$1_bl > ${P}_$1.cmp
}
run L1p lives_p1,invuln_p1 &
run L2p lives_p1,lives_p2,invuln_p1,invuln_p2 &
run Lnc "" &
wait
for x in L1p L2p Lnc; do echo "== $x"; cut -c1-300 ${P}_$x.cmp; done
