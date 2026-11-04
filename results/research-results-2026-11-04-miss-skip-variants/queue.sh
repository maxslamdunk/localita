#!/bin/bash
# The scored runs, in order: the two controls, then the variants. Scored
# against this folder's refs/ref.ref, which must be byte-identical to the
# 2026-10-04 one (control 1 in predictions.md).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/sequences.json"
N=128
run() { bash "$here/score.sh" "$@" || echo "run $1 failed: $?"; }
K=TURBO_FIELDFARE_EXPERT_SKIP
run ref "$S" $N ref
old=/Users/max/ml_projects/iphone-port/turbo-fieldfare/.claude/worktrees/expert-compression/research-results-2026-10-04-lossy-experts/refs/ref.ref
if cmp "$here/refs/ref.ref" "$old"; then echo "ref identical to 2026-10-04"; else echo "ref DIFFERS from 2026-10-04; stopping"; exit 1; fi
run miss08 "$S" $N ref $K=miss:0.08
run cum0.85 "$S" $N ref $K=cum:0.85
run cum0.80 "$S" $N ref $K=cum:0.80
run early0.10 "$S" $N ref $K=early:0.10
run early0.30 "$S" $N ref $K=early:0.30
run miss08+early0.30 "$S" $N ref "$K=miss:0.08+early:0.30"
run bias05+miss08 "$S" $N ref "$K=bias:0.05+miss:0.08"
echo "queue done $(date)"
