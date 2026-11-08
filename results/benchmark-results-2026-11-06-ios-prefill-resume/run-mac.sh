#!/bin/bash
# Mac check: greedy text must match step 3's arm A. Defaults only (layer at a
# time on). Resumable: a case whose log already has its footer is skipped.
set -u
cd "$(dirname "$0")/../.."
OUT=results/benchmark-results-2026-11-06-ios-prefill-resume/mac-check
mkdir -p "$OUT"
BIN=$(swift build -c release --show-bin-path)/TurboFieldfareCLI
M=${MODEL:-/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/gemma4.gturbo}
for c in medium-review long-synthesis; do
    f=$OUT/$c-A
    if grep -q "prefill-time" "$f.log" 2>/dev/null; then echo "$(date +%H:%M:%S) skip $c"; continue; fi
    echo "$(date +%H:%M:%S) start $c"
    caffeinate -i "$BIN" --model "$M" --messages-file docs/benchmark-prompts/real-generation-v1/$c.json \
        --max-new 48 --temperature 0 > "$f.txt" 2> "$f.log"
    echo "$(date +%H:%M:%S) done $c exit $?: $(grep -o 'prefill bytes=[0-9.]*MB[^|]*' "$f.log" | head -1)"
done
shasum -a 256 "$OUT"/*.txt results/benchmark-results-2026-11-06-ios-prefill-layer-major/mac-check/*-A.txt
