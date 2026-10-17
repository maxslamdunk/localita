#!/bin/bash
# Three and four early reads per layer on the M1; see
# predictions-three-four-reads.md. Same protocol as run-two-reads.sh, plus one
# warmup run. Per case: x2, x3, x4, x4, x3, x2. Run from the early-read
# checkout's root after a release build, with MODEL=<path>. Results go to
# benchmark-results-three-four-reads/.
set -u
MODEL=${MODEL:?set MODEL}
PAUSE=${PAUSE:-120}
OUT=benchmark-results-three-four-reads
CLI=.build/release/TurboFieldfareCLI
PROMPTS=docs/benchmark-prompts/real-generation-v1
PREFLIGHT='TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'
mkdir -p "$OUT/measured" "$OUT/warmup"
{ git rev-parse HEAD; sw_vers; df -h / | tail -1; pmset -g batt; } > "$OUT/system.txt" 2>&1

run() { # case seed reads dir label
  if pgrep -fl "$PREFLIGHT"; then
    echo "Another model process is running; stopping." >&2; exit 1
  fi
  echo "$(date '+%H:%M:%S') $1 $5" | tee -a "$OUT/progress.txt"
  { date; pmset -g therm; memory_pressure -Q; } > "$OUT/$4/$1-$5.conditions" 2>&1
  TURBO_FIELDFARE_EARLY_EXPERT_READS=$3 "$CLI" --model "$MODEL" \
    --messages-file "$PROMPTS/$1.json" --max-new 1024 --max-context 4096 \
    --temperature 0.2 --top-k 64 --top-p 0.95 --seed "$2" \
    --early-expert-read fitted \
    > "$OUT/$4/$1-$5.stdout" 2> "$OUT/$4/$1-$5.stderr"
}

run short-explanation 20260721 2 warmup 0-fitted2

for case_seed in short-explanation:20260721 medium-review:20260722 long-synthesis:20260723; do
  c=${case_seed%%:*}; seed=${case_seed##*:}; n=0
  for reads in 2 3 4 4 3 2; do
    n=$((n + 1))
    sleep "$PAUSE"
    run "$c" "$seed" "$reads" measured "$n-fitted$reads"
  done
done

for f in "$OUT"/measured/*.stderr; do
  printf '%s %s %s %s\n' "$(basename "$f" .stderr)" "$(shasum -a 256 "${f%.stderr}.stdout" | cut -c1-16)" \
    "$(grep -h '^\[stop=' "$f")" "$(grep -h '^\[early-read' "$f")"
done | tee "$OUT/summary.txt"
