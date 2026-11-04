#!/bin/bash
# Free-running greedy generations of two real-generation-v1 prompts, with and
# without expert skipping, for reading side by side. Mac, 24 slots, defaults
# otherwise. Output text goes to gen/<label>-<case>.txt, footers to .err.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
model=/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/gemma4.gturbo
prompts="$root/docs/benchmark-prompts/real-generation-v1"
mkdir -p "$here/gen"
for spec in "base:" "miss08:miss:0.08" "miss10:miss:0.10"; do
    label=${spec%%:*}
    skip=${spec#*:}
    for case in short-explanation medium-review; do
        if pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm|TurboFieldfareScore' >/dev/null; then
            echo "another model-owning process is running; stopping" >&2
            exit 3
        fi
        TURBO_FIELDFARE_EXPERT_SKIP="$skip" "$root/.build/release/TurboFieldfareCLI" \
            --model "$model" --messages-file "$prompts/$case.json" \
            --expert-cache-slots 24 --temperature 0 --max-new 600 --max-context 4096 \
            > "$here/gen/$label-$case.txt" 2> "$here/gen/$label-$case.err"
        echo "$label $case: $(grep -E '^\[stop' "$here/gen/$label-$case.err")"
    done
done
