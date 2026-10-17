#!/bin/bash
# The community benchmark (docs/COMMUNITY_BENCHMARKS.md), with each case
# measured six times across the early-read setting in the order
# off, router, fitted, fitted, router, off.
#
# Run from the root of a checkout of the early-read branch, after
# `swift build -c release --product TurboFieldfareCLI`, with the model at
# scratch/gemma4.gturbo (or MODEL=<path>). Results go to benchmark-results/.
# Takes about 1.5-2.5 hours: 3 warmups + 18 measured runs, with a 2-minute
# pause between runs (PAUSE=<seconds> to change it).
set -u
MODEL=${MODEL:-scratch/gemma4.gturbo}
PAUSE=${PAUSE:-120}
OUT=benchmark-results
CLI=.build/release/TurboFieldfareCLI
PROMPTS=docs/benchmark-prompts/real-generation-v1

preflight() {
  if pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'; then
    echo "Another model process is running; stopping." >&2
    exit 1
  fi
}

run_case() {  # <dir> <case> <seed> <label> <early-read setting>
  preflight
  echo "$(date '+%H:%M:%S') $2 $4 $5" | tee -a "$OUT/progress.txt"
  { date; pmset -g therm; memory_pressure -Q; } > "$OUT/$1/$2-$4.conditions" 2>&1
  "$CLI" \
    --model "$MODEL" \
    --messages-file "$PROMPTS/$2.json" \
    --max-new 1024 \
    --max-context 4096 \
    --temperature 0.2 \
    --top-k 64 \
    --top-p 0.95 \
    --seed "$3" \
    --early-expert-read "$5" \
    > "$OUT/$1/$2-$4.stdout" \
    2> "$OUT/$1/$2-$4.stderr"
}

mkdir -p "$OUT/system" "$OUT/warmup" "$OUT/measured"
preflight
{
  git status --short
  git rev-parse HEAD
  sw_vers
  swift --version
  system_profiler SPHardwareDataType |
    awk -F': ' '/Model Name|Model Identifier|Chip|Total Number of Cores|Memory/ { print $1 ": " $2 }'
  shasum -a 256 "$MODEL/manifest.json"
  shasum -a 256 "$PROMPTS"/*.json
  pmset -g batt
  df -h / | tail -1
  echo "TURBO_FIELDFARE_EARLY_EXPERT_READS=${TURBO_FIELDFARE_EARLY_EXPERT_READS:-unset}"
} 2>&1 | tee "$OUT/system/system.txt"

CASES="short-explanation:20260721 medium-review:20260722 long-synthesis:20260723"

for case_seed in $CASES; do
  run_case warmup "${case_seed%%:*}" "${case_seed##*:}" warmup fitted
done

for case_seed in $CASES; do
  n=0
  for setting in off router fitted fitted router off; do
    n=$((n + 1))
    sleep "$PAUSE"
    run_case measured "${case_seed%%:*}" "${case_seed##*:}" "$n-$setting" "$setting"
  done
done

# One line per run: the timing footer and the early-read line.
for f in "$OUT"/measured/*.stderr; do
  printf '%s %s %s\n' "$(basename "$f" .stderr)" \
    "$(grep -h '^\[stop=' "$f")" "$(grep -h '^\[early-read' "$f")"
done | tee "$OUT/summary.txt"

# Generated text must be identical across the six runs of each case.
for case_seed in $CASES; do
  echo "${case_seed%%:*}: $(shasum -a 256 "$OUT"/measured/"${case_seed%%:*}"-*.stdout |
    awk '{print $1}' | sort -u | wc -l | tr -d ' ') distinct output(s) of 6"
done | tee -a "$OUT/summary.txt"
