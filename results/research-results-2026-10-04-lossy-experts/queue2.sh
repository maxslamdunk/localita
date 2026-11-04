#!/bin/bash
# Second queue: the two runs the first queue wrote as references by mistake
# (score.sh's mode bug; their logs are kept as *-refmode.txt), and
# cache-prior reranking. Binary built at 63a1f08.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/sequences.json"
N=128
run() { bash "$here/score.sh" "$@" || echo "run $1 failed: $?"; }
L=TURBO_FIELDFARE_LOSSY_EXPERTS
K=TURBO_FIELDFARE_EXPERT_SKIP
for name in noise miss05; do
    [ -f "$here/logs/$name.txt" ] && mv "$here/logs/$name.txt" "$here/logs/$name-refmode.txt"
done
run noise "$S" $N ref $L=noise=0.0833333
run bias05 "$S" $N ref $K=bias:0.05
run bias10 "$S" $N ref $K=bias:0.10
run miss05 "$S" $N ref $K=miss:0.05
echo "queue2 done $(date)"
