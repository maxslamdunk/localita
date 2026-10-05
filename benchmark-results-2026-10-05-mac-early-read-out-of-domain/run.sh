#!/bin/bash
# Router vs fitted next-layer guess on six prompts outside the fit's training
# set; see predictions.md. Run from the root of the early-read-fitted
# checkout after a release build:
#   MODEL=<abs path to gemma4.gturbo> <this folder>/run.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MODEL=${MODEL:?set MODEL}
CLI=.build/release/TurboFieldfareCLI
OUT="$HERE/runs"
mkdir -p "$OUT"
{ git rev-parse HEAD; git status --short; sw_vers; df -h / | tail -1; } > "$OUT/system.txt" 2>&1

# prompt:seed:max-new, each run router then fitted or the reverse, alternating.
i=0
for spec in ru-history:20261012:600 zh-explain:20261015:500 es-recipe:20261014:500 \
            story:20261018:800 multi-turn:20261026:500 sql-debug:20261005:500; do
  IFS=: read -r name seed maxnew <<< "$spec"
  if (( i % 2 == 0 )); then order="router fitted"; else order="fitted router"; fi
  i=$((i + 1))
  for guess in $order; do
    if pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'; then
      echo "Another model process is running; stopping." >&2; exit 1
    fi
    echo "$(date '+%H:%M:%S') $name $guess" | tee -a "$OUT/progress.txt"
    { date; pmset -g therm; memory_pressure -Q; } > "$OUT/$name-$guess.conditions" 2>&1
    "$CLI" --model "$MODEL" --messages-file "$HERE/prompts/$name.json" \
      --max-new "$maxnew" --max-context 4096 \
      --temperature 0.2 --top-k 64 --top-p 0.95 --seed "$seed" \
      --early-expert-read "$guess" \
      > "$OUT/$name-$guess.stdout" 2> "$OUT/$name-$guess.stderr"
  done
done

for f in "$OUT"/*.stderr; do
  printf '%s %s %s %s\n' "$(basename "$f" .stderr)" "$(shasum -a 256 "${f%.stderr}.stdout" | cut -c1-16)" \
    "$(grep -h '^\[stop=' "$f")" "$(grep -h '^\[early-read' "$f")"
done | tee "$OUT/summary.txt"
