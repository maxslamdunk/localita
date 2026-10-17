#!/bin/bash
# Counters only: which layers the early read's hits land in; see predictions.md.
# Run from the early-read checkout's root on scratch-early-read-cleared-layers
# (1a4c9ab plus instrumentation.diff) after a release build, with MODEL=<path>.
# Results go to benchmark-results-cleared-layers/.
set -u
MODEL=${MODEL:?set MODEL}
OUT=benchmark-results-cleared-layers
CLI=.build/release/TurboFieldfareCLI
PROMPTS=docs/benchmark-prompts/real-generation-v1
mkdir -p "$OUT/measured"
{ git rev-parse HEAD; git status --short; sw_vers; pmset -g batt; } > "$OUT/system.txt" 2>&1

for case_seed in short-explanation:20260721 medium-review:20260722 long-synthesis:20260723; do
  c=${case_seed%%:*}; seed=${case_seed##*:}
  for setting in router fitted router2 fitted2; do
    # Resumable: a finished run is skipped.
    grep -qs '^\[stop=' "$OUT/measured/$c-$setting.stderr" && continue
    # The editor's index builds name package targets such as
    # TurboFieldfareMacPresentation; they are compilers, not model processes.
    if pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm' \
        | grep -v -E '/usr/bin/swift-(build|driver|frontend) '; then
      echo "Another model process is running; stopping." >&2; exit 1
    fi
    guess=${setting%2}; reads=1; [ "$guess" != "$setting" ] && reads=2
    echo "$(date '+%H:%M:%S') $c $setting" | tee -a "$OUT/progress.txt"
    { date; pmset -g therm; memory_pressure -Q; } > "$OUT/measured/$c-$setting.conditions" 2>&1
    TURBO_FIELDFARE_EARLY_EXPERT_READS=$reads "$CLI" --model "$MODEL" \
      --messages-file "$PROMPTS/$c.json" --max-new 1024 --max-context 4096 \
      --temperature 0.2 --top-k 64 --top-p 0.95 --seed "$seed" \
      --early-expert-read "$guess" \
      > "$OUT/measured/$c-$setting.stdout" 2> "$OUT/measured/$c-$setting.stderr"
  done
done

for f in "$OUT"/measured/*.stderr; do
  printf '%s %s\n%s\n%s\n' "$(basename "$f" .stderr)" "$(shasum -a 256 "${f%.stderr}.stdout" | cut -c1-16)" \
    "$(grep -h '^\[early-read ' "$f")" "$(grep -h '^\[early-read-layers' "$f")"
done | tee "$OUT/summary.txt"
