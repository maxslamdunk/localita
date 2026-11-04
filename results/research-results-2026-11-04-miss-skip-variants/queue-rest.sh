#!/bin/bash
# The six variant runs from queue.sh, restarted after a model-using test in
# another worktree made score.sh's guard skip them on the first pass. The
# controls (ref, miss08) had already passed and are not rerun. Before each
# run it waits until no model-owning process (or a build of one) has been
# seen for two minutes, because that worktree builds and tests in bursts.
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
run() { wait_clear; echo "start $1 $(date '+%H:%M:%S')"; bash "$here/score.sh" "$@" || echo "run $1 failed: $?"; }
K=TURBO_FIELDFARE_EXPERT_SKIP
run cum0.85 "$S" $N ref $K=cum:0.85
run cum0.80 "$S" $N ref $K=cum:0.80
run early0.10 "$S" $N ref $K=early:0.10
run early0.30 "$S" $N ref $K=early:0.30
run miss08+early0.30 "$S" $N ref "$K=miss:0.08+early:0.30"
run bias05+miss08 "$S" $N ref "$K=bias:0.05+miss:0.08"
echo "queue done $(date)"
