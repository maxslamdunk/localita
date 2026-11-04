#!/bin/bash
# Runs the quality meter once.
#
#   score.sh <label> <sequences.json> <max-tokens> <label>     writes refs/<label>.ref
#   score.sh <label> <sequences.json> <max-tokens> <ref-label> [VAR=value ...]
#
# A run writes a reference when its ref-label is its own label; otherwise it
# is scored against refs/<ref-label>.ref.
#
# Extra VAR=value pairs are exported for that run only (the lossy-expert
# simulation and the expert-skip policy are set this way). Output goes to
# logs/<label>.txt and per-position detail to logs/<label>.pos. Stops if
# another model-owning process is running.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
model=/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/gemma4.gturbo
label=$1 sequences=$2 maxtok=$3 ref=$4
shift 4
mkdir -p "$here/logs" "$here/refs"
if pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm|TurboFieldfareScore'; then
    echo "another model-owning process is running; not starting" >&2
    exit 3
fi
for pair in "$@"; do export "$pair"; done
out="$here/logs/$label.txt"
{
    echo "# $(date '+%Y-%m-%d %H:%M:%S') commit $(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet || echo '+dirty')"
    echo "# label=$label sequences=$(basename "$sequences") max-tokens=$maxtok ref=$ref env: $*"
    echo "# $(memory_pressure -Q | tail -1); thermal: $(pmset -g therm | grep -i 'CPU_Speed_Limit' | tr -s ' ' || true)"
} > "$out"
if [ "$ref" = "$label" ]; then
    "$root/.build/release/TurboFieldfareScore" --model "$model" --sequences "$sequences" \
        --max-tokens "$maxtok" --slots 24 --ref-out "$here/refs/$label.ref" >> "$out" 2>&1
else
    "$root/.build/release/TurboFieldfareScore" --model "$model" --sequences "$sequences" \
        --max-tokens "$maxtok" --slots 24 --ref "$here/refs/$ref.ref" \
        --positions-out "$here/logs/$label.pos" >> "$out" 2>&1
fi
echo "# done $(date '+%H:%M:%S'); $(sysctl -n vm.swapusage)" >> "$out"
tail -4 "$out"
