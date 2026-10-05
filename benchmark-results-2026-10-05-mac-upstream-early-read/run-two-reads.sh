#!/bin/bash
# Two early reads per layer on the M1; see predictions-two-reads.md. Same
# protocol as run-early-read-benchmark.sh, per case: fitted, fitted x2,
# fitted x2, fitted. Run from the early-read checkout's root after a release
# build, with MODEL=<path>. Results go to benchmark-results-two-reads/.
set -u
MODEL=${MODEL:?set MODEL}
PAUSE=${PAUSE:-120}
OUT=benchmark-results-two-reads
CLI=.build/release/TurboFieldfareCLI
PROMPTS=docs/benchmark-prompts/real-generation-v1
mkdir -p "$OUT/measured"
{ git rev-parse HEAD; sw_vers; df -h / | tail -1; pmset -g batt; } > "$OUT/system.txt" 2>&1

for case_seed in short-explanation:20260721 medium-review:20260722 long-synthesis:20260723; do
  c=${case_seed%%:*}; seed=${case_seed##*:}; n=0
  for reads in 1 2 2 1; do
    n=$((n + 1))
    sleep "$PAUSE"
    if pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'; then
      echo "Another model process is running; stopping." >&2; exit 1
    fi
    label="$n-fitted$([ "$reads" = 2 ] && echo 2)"
    echo "$(date '+%H:%M:%S') $c $label" | tee -a "$OUT/progress.txt"
    { date; pmset -g therm; memory_pressure -Q; } > "$OUT/measured/$c-$label.conditions" 2>&1
    TURBO_FIELDFARE_EARLY_EXPERT_READS=$reads "$CLI" --model "$MODEL" \
      --messages-file "$PROMPTS/$c.json" --max-new 1024 --max-context 4096 \
      --temperature 0.2 --top-k 64 --top-p 0.95 --seed "$seed" \
      --early-expert-read fitted \
      > "$OUT/measured/$c-$label.stdout" 2> "$OUT/measured/$c-$label.stderr"
  done
done

for f in "$OUT"/measured/*.stderr; do
  printf '%s %s %s %s\n' "$(basename "$f" .stderr)" "$(shasum -a 256 "${f%.stderr}.stdout" | cut -c1-16)" \
    "$(grep -h '^\[stop=' "$f")" "$(grep -h '^\[early-read' "$f")"
done | tee "$OUT/summary.txt"
