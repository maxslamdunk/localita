#!/bin/bash
# The last variant run from queue.sh, which queue-rest.sh lost to a race with
# a test in another worktree, then the three extra `miss` curve points of
# Addendum 1 in predictions.md. Before each run it waits until no
# model-owning process (or a build of one) has been seen for two minutes, and
# a run the guard blocks is retried after the next wait.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/sequences.json"
N=128
pat='TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm|TurboFieldfareScore'
wait_clear() {
    local clear=0
    while [ $clear -lt 4 ]; do
        if pgrep -f "$pat" >/dev/null; then clear=0; else clear=$((clear + 1)); fi
        sleep 30
    done
}
run() {
    local try
    for try in 1 2 3 4 5 6; do
        wait_clear
        echo "start $1 try $try $(date '+%H:%M:%S')"
        bash "$here/score.sh" "$@" && return
        echo "run $1 failed: $?"
    done
}
K=TURBO_FIELDFARE_EXPERT_SKIP
run bias05+miss08 "$S" $N ref "$K=bias:0.05+miss:0.08"
run miss07 "$S" $N ref $K=miss:0.07
run miss075 "$S" $N ref $K=miss:0.075
run miss085 "$S" $N ref $K=miss:0.085
echo "queue done $(date)"
