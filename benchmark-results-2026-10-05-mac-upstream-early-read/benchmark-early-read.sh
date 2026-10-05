#!/bin/bash
# The community benchmark (docs/COMMUNITY_BENCHMARKS.md), with each case
# measured eight times across the early-read setting, in the order
#   off, router, fitted, fitted x2, fitted x2, fitted, router, off
# where "fitted x2" reads two experts per layer early
# (TURBO_FIELDFARE_EARLY_EXPERT_READS=2). See EARLY_READ_BENCHMARK.md.
#
# Run from the repository root after
#   swift build -c release --product TurboFieldfareCLI
# with the model at scratch/gemma4.gturbo (or MODEL=<path>).
# Results go to benchmark-results/. About 2-3 hours on an M1; a 2-minute
# pause precedes each measured run (PAUSE=<seconds> to change it).
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

run_case() {  # <dir> <case> <seed> <label> <setting: off|router|fitted|fitted2>
  local setting=$5 reads=1
  if [ "$setting" = fitted2 ]; then setting=fitted; reads=2; fi
  preflight
  echo "$(date '+%H:%M:%S') $2 $4" | tee -a "$OUT/progress.txt"
  { date; pmset -g therm; memory_pressure -Q; } > "$OUT/$1/$2-$4.conditions" 2>&1
  TURBO_FIELDFARE_EARLY_EXPERT_READS=$reads "$CLI" \
    --model "$MODEL" \
    --messages-file "$PROMPTS/$2.json" \
    --max-new 1024 \
    --max-context 4096 \
    --temperature 0.2 \
    --top-k 64 \
    --top-p 0.95 \
    --seed "$3" \
    --early-expert-read "$setting" \
    > "$OUT/$1/$2-$4.stdout" \
    2> "$OUT/$1/$2-$4.stderr"
}

if [ ! -x "$CLI" ]; then
  echo "Build first: swift build -c release --product TurboFieldfareCLI" >&2
  exit 1
fi
mkdir -p "$OUT/system" "$OUT/warmup" "$OUT/measured"
preflight
{
  git status --short
  git rev-parse HEAD
  sw_vers
  swift --version
  system_profiler SPHardwareDataType |
    awk -F': ' '/Model Name|Model Identifier|Chip|Total Number of Cores|Memory/ { print $1 ": " $2 }'
  (cd "$MODEL" && shasum -a 256 manifest.json)
  shasum -a 256 "$PROMPTS"/*.json
  pmset -g batt
  df -h / | tail -1
} 2>&1 | tee "$OUT/system/system.txt"

CASES="short-explanation:20260721 medium-review:20260722 long-synthesis:20260723"

for case_seed in $CASES; do
  run_case warmup "${case_seed%%:*}" "${case_seed##*:}" warmup fitted
done

for case_seed in $CASES; do
  n=0
  for setting in off router fitted fitted2 fitted2 fitted router off; do
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

# Generated text must be identical across the eight runs of each case.
for case_seed in $CASES; do
  echo "${case_seed%%:*}: $(shasum -a 256 "$OUT"/measured/"${case_seed%%:*}"-*.stdout |
    awk '{print $1}' | sort -u | wc -l | tr -d ' ') distinct output(s) of 8"
done | tee -a "$OUT/summary.txt"

# A zip of everything, and the pre-filled benchmark issue.
ditto -c -k --keepParent "$OUT" benchmark-results.zip
python3 Scripts/early-read-report.py "$OUT"
