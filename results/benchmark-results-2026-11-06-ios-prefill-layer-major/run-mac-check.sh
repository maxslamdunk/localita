#!/bin/bash
# Mac check: greedy text must match across arms. A = default (layer at a
# time), B = TURBO_FIELDFARE_PREFILL_LAYER_MAJOR=0. Resumable: a case whose
# log already has its footer is skipped.
set -u
cd "$(dirname "$0")/../.."
OUT=results/benchmark-results-2026-11-06-ios-prefill-layer-major/mac-check
mkdir -p "$OUT"
BIN=$(swift build -c release --show-bin-path)/TurboFieldfareCLI
M=${MODEL:-/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/gemma4.gturbo}
for arm in A B; do
    for c in medium-review long-synthesis; do
        f=$OUT/$c-$arm
        if grep -q "prefill-time" "$f.log" 2>/dev/null; then echo "$(date +%H:%M:%S) skip $arm $c"; continue; fi
        echo "$(date +%H:%M:%S) start $arm $c"
        if [ $arm = B ]; then export TURBO_FIELDFARE_PREFILL_LAYER_MAJOR=0; else unset TURBO_FIELDFARE_PREFILL_LAYER_MAJOR; fi
        caffeinate -i "$BIN" --model "$M" --messages-file docs/benchmark-prompts/real-generation-v1/$c.json \
            --max-new 48 --temperature 0 > "$f.txt" 2> "$f.log"
        echo "$(date +%H:%M:%S) done $arm $c exit $?: $(grep -o 'prefill bytes=[0-9.]*MB[^|]*' "$f.log" | head -1)"
    done
done
shasum -a 256 "$OUT"/*.txt
