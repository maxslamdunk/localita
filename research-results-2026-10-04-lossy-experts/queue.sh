#!/bin/bash
# The scored runs, in order: reference, determinism check, yardstick, expert
# skipping (fast), lower-bit formats (slow: the in-place rewrite costs CPU).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/sequences.json"
N=128
run() { bash "$here/score.sh" "$@" || echo "run $1 failed: $?"; }
L=TURBO_FIELDFARE_LOSSY_EXPERTS
K=TURBO_FIELDFARE_EXPERT_SKIP
run ref "$S" $N ref
run ref-again "$S" $N ref
run noise "$S" $N ref $L=noise=0.0833333
run miss05 "$S" $N ref $K=miss:0.05
run miss08 "$S" $N ref $K=miss:0.08
run miss10 "$S" $N ref $K=miss:0.10
run missrank7 "$S" $N ref $K=missrank:7
run top7 "$S" $N ref $K=topk:7
run misssub08 "$S" $N ref $K=misssub:0.08
run miss08-nonorm "$S" $N ref $K=miss:0.08:nonorm
run all3 "$S" $N ref $L=all=3
run cold50-3 "$S" $N ref "$L=all=3,experts=$here/cold-50.txt"
run gateup3 "$S" $N ref $L=gate=3,up=3
run down3 "$S" $N ref $L=down=3
run all2 "$S" $N ref $L=all=2
echo "queue done $(date)"
