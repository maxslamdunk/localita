#!/bin/bash
# The community benchmark (docs/COMMUNITY_BENCHMARKS.md), measuring the early
# expert read. See EARLY_READ_BENCHMARK.md.
#
# Each case runs the order
#   off, router, fitted, fitted x2, fitted x2, fitted, router, off
# twice in a row, after one discarded warmup. Every comparison (router vs off,
# fitted vs router, fitted x2 vs fitted) is then made between adjacent runs,
# four times per case, so slow changes in the Mac's speed cancel within each
# pair. Adjacent runs of the same setting show the run-to-run noise.
#
# "x2" reads 2 experts per layer early (TURBO_FIELDFARE_EARLY_EXPERT_READS=2).
#
# Run from the repository root after
#   swift build -c release --product TurboFieldfareCLI
# with the model at scratch/gemma4.gturbo (or MODEL=<path>).
# Results go to benchmark-results/. About 3 hours on a 16 GB Mac and 5 on an
# 8 GB one; a 2-minute pause precedes each run (PAUSE=<seconds> to change it).
# If it stops, run it again: finished runs are kept and skipped.
# SETTINGS=<order> and BLOCKS=<count> change the order and how many times it
# runs per case; OUT=<dir> changes the results folder.
set -u
VERSION=v3
MODEL=${MODEL:-scratch/gemma4.gturbo}
PAUSE=${PAUSE:-120}
OUT=${OUT:-benchmark-results}
SETTINGS=${SETTINGS:-off router fitted fitted2 fitted2 fitted router off}
BLOCKS=${BLOCKS:-2}
CLI=${CLI:-.build/release/TurboFieldfareCLI}
PROMPTS=docs/benchmark-prompts/real-generation-v1
CASES="short-explanation:20260721 medium-review:20260722 long-synthesis:20260723"
HEADER="Benchmark: early-read $VERSION; order: $SETTINGS; blocks: $BLOCKS"
failures=0

preflight() {
  # The Swift toolchain's own processes (an editor's index build, for one)
  # can name package targets; they are not model processes.
  if pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm' |
      grep -v -E '/swift-(build|driver|frontend) '; then
    echo "Another model process is running; stopping. Run the script again when it has finished." >&2
    exit 1
  fi
}

on_power() {
  pmset -g batt | grep -q "'AC Power'"
}

low_power_mode() {
  pmset -g | awk '/lowpowermode/ { found = ($2 == 1) } END { exit !found }'
}

run_case() {  # <dir> <case> <seed> <label> <setting: off|router|fitted, optionally with a read count>
  local setting=${5%[0-9]} reads=${5##*[a-z]}
  reads=${reads:-1}
  local base="$OUT/$1/$2-$4"
  preflight
  echo "$(date '+%H:%M:%S') $1 $2 $4" | tee -a "$OUT/progress.txt"
  {
    date
    pmset -g batt | head -1
    pmset -g therm
    memory_pressure -Q
    echo "Busiest processes:"
    ps -Ao pcpu,pmem,comm -r | head -8
  } > "$base.conditions" 2>&1
  if ! TURBO_FIELDFARE_EARLY_EXPERT_READS=$reads "$CLI" \
    --model "$MODEL" \
    --messages-file "$PROMPTS/$2.json" \
    --max-new 1024 \
    --max-context 4096 \
    --temperature 0.2 \
    --top-k 64 \
    --top-p 0.95 \
    --seed "$3" \
    --early-expert-read "$setting" \
    > "$base.stdout" \
    2> "$base.stderr"; then
    failures=$((failures + 1))
    echo "This run failed; see $base.stderr." | tee -a "$OUT/progress.txt"
    if [ "$failures" -ge 2 ]; then
      echo "Two runs in a row failed; stopping. Run the script again to continue." | tee -a "$OUT/progress.txt"
      exit 1
    fi
  else
    failures=0
  fi
}

finished() {  # <stderr path>
  grep -qs '^\[stop=' "$1"
}

if [ ! -x "$CLI" ]; then
  echo "Build first: swift build -c release --product TurboFieldfareCLI" >&2
  exit 1
fi
if [ ! -f "$MODEL/manifest.json" ]; then
  echo "No model at $MODEL. Install it (see EARLY_READ_BENCHMARK.md) or pass MODEL=<path>." >&2
  exit 1
fi
if [ -e "$OUT" ] && ! grep -qsxF "$HEADER" "$OUT/system/header.txt"; then
  echo "$OUT/ holds results from another version of this benchmark. Keep them under another name:" >&2
  echo "  mv $OUT $OUT-before-$VERSION" >&2
  [ -e "$OUT.zip" ] && echo "  mv $OUT.zip $OUT-before-$VERSION.zip" >&2
  exit 1
fi
if ! on_power; then
  echo "Connect the Mac to power; the benchmark does not run on battery." >&2
  exit 1
fi
if low_power_mode; then
  echo "Turn off Low Power Mode (System Settings > Battery) and run again." >&2
  exit 1
fi
preflight

mkdir -p "$OUT/system" "$OUT/warmup" "$OUT/measured"
echo "$HEADER" > "$OUT/system/header.txt"
# Keep the Mac and its display awake until this script exits.
caffeinate -dims -w $$ &

# One system file per start, so a resumed benchmark keeps both.
{
  echo "$HEADER"
  echo "Pause: $PAUSE"
  git status --short
  git rev-parse HEAD
  sw_vers
  swift --version
  system_profiler SPHardwareDataType |
    awk -F': ' '/Model Name|Model Identifier|Chip|Total Number of Cores|Memory/ { print $1 ": " $2 }'
  (cd "$MODEL" && shasum -a 256 manifest.json)
  shasum -a 256 "$PROMPTS"/*.json
  pmset -g batt
  pmset -g | grep -i lowpowermode
  df -h / | tail -1
} > "$OUT/system/system-$(date '+%Y%m%d-%H%M%S').txt" 2>&1
cp "$(ls "$OUT"/system/system-*.txt | tail -1)" "$OUT/system/system.txt"
cat "$OUT/system/system.txt"

for case_seed in $CASES; do
  c=${case_seed%%:*}
  seed=${case_seed##*:}
  warm=0
  n=0
  for block in $(seq "$BLOCKS"); do
    for setting in $SETTINGS; do
      n=$((n + 1))
      finished "$OUT/measured/$c-$n-$setting.stderr" && continue
      if [ "$warm" = 0 ]; then
        # Discarded: the first run of a case after other work starts colder.
        run_case warmup "$c" "$seed" warmup fitted2
        warm=1
      fi
      sleep "$PAUSE"
      run_case measured "$c" "$seed" "$n-$setting" "$setting"
    done
  done
done

# One line per run, in run order: the timing footer and the early-read line.
for case_seed in $CASES; do
  c=${case_seed%%:*}
  n=0
  for block in $(seq "$BLOCKS"); do
    for setting in $SETTINGS; do
      n=$((n + 1))
      f="$OUT/measured/$c-$n-$setting.stderr"
      [ -e "$f" ] || continue
      printf '%s %s %s\n' "$c-$n-$setting" \
        "$(grep -h '^\[stop=' "$f")" "$(grep -h '^\[early-read' "$f")"
    done
  done
done > "$OUT/summary.txt"

# Generated text must be identical across the runs of each case.
for case_seed in $CASES; do
  c=${case_seed%%:*}
  files=()
  for f in "$OUT"/measured/"$c"-*.stdout; do
    [ -e "$f" ] && files+=("$f")
  done
  [ ${#files[@]} -gt 0 ] || continue
  echo "$c: $(shasum -a 256 "${files[@]}" | awk '{print $1}' | sort -u |
    wc -l | tr -d ' ') distinct output(s) of ${#files[@]}"
done >> "$OUT/summary.txt"
cat "$OUT/summary.txt"

# A zip of everything, and the pre-filled benchmark issue, opened in the browser.
rm -f "$OUT.zip"
ditto -c -k --keepParent "$OUT" "$OUT.zip"
python3 Scripts/early-read-report.py "$OUT"
if [ -s "$OUT/issue-link.txt" ]; then
  open "$(cat "$OUT/issue-link.txt")"
fi
