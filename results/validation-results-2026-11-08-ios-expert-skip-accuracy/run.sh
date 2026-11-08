#!/bin/bash
# Expert-skip accuracy check on the phone: 50 GSM-Symbolic P2 problems in one
# `--session` per arm, A (off) then B (miss:0.08). Answers are graded, not
# timed, so there is one run per arm and a short cooldown. Adapted from
# benchmark-results-2026-11-08-ios-expert-skip/lib.sh.
#
# usage: PROMPTS=<dir of gsmp2-NN.json from make_prompts.py> run.sh
set -u
D=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BID=io.github.maxslamdunk.Localita
PROMPTS=${PROMPTS:?set PROMPTS to the make_prompts.py output folder}
S=${TMPDIR:-/tmp}
OUT=$(cd "$(dirname "$0")" && pwd)/logs
mkdir -p "$OUT"
say() { echo "$(date +%H:%M:%S) $*"; }
docs() {
    xcrun devicectl device info files --device $D --domain-type appDataContainer \
        --domain-identifier $BID --subdirectory Documents 2>/dev/null | awk '{print $1}'
}
pull() {  # file in Documents
    xcrun devicectl device copy from --device $D --domain-type appDataContainer \
        --domain-identifier $BID --source "Documents/$1" --destination "$OUT/$1" >/dev/null 2>&1
}

CASES=$(ls "$PROMPTS" | sed -n 's/^\(gsmp2-[0-9][0-9]\)\.json$/\1/p' | paste -sd, -)
[ "$(echo "$CASES" | tr , '\n' | wc -l | tr -d ' ')" = 50 ] || { say "FAIL: expected 50 prompts in $PROMPTS"; exit 1; }
say "push 50 prompts"
for f in "$PROMPTS"/gsmp2-*.json; do
    xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $BID \
        --source "$f" --destination "Documents/prompts/$(basename "$f")" >/dev/null 2>"$S/push.err" \
        || { say "FAIL push $f: $(tail -2 $S/push.err)"; exit 1; }
done

arm() {  # label [extra launch args]
    local label=$1; shift
    if grep -lq ', session-done, ' "$OUT"/decode-$label-*.log 2>/dev/null; then say "skip $label (done)"; return 0; fi
    say "launch $label"
    local attempt
    for attempt in 1 2 3; do
        xcrun devicectl device process launch --device $D --terminate-existing $BID \
            --autorun --session "$CASES" --label $label --slots 24 --max-new 1024 --max-context 4096 "$@" \
            >/dev/null 2>"$S/launch.err" && break
        [ $attempt -lt 3 ] || { say "FAIL launch $label: $(tail -2 $S/launch.err)"; exit 1; }
        say "launch $label failed (attempt $attempt)"; sleep 20
    done
    local t0=$(date +%s) file="" misses=0 seen=0
    while true; do
        sleep 60
        file=$(docs | grep "^decode-$label-.*Z\.log$" | tail -1)
        if [ -n "$file" ]; then
            pull "$file"
            local n=$(grep -c ', generated, ' "$OUT/$file" 2>/dev/null)
            [ "$n" != "$seen" ] && { say "$label: $n of 50"; seen=$n; }
            if grep -q ', session-done, ' "$OUT/$file"; then
                for t in $(docs | grep "^${file%.log}-gsmp2-.*\.txt$"); do pull "$t"; done
                say "done $label: $(ls "$OUT"/${file%.log}-gsmp2-*.txt | wc -l | tr -d ' ') texts"
                return 0
            fi
        fi
        local procs
        if procs=$(xcrun devicectl device info processes --device $D 2>/dev/null); then
            if echo "$procs" | grep -q '/TurboFieldfareiOS.app/TurboFieldfareiOS'; then misses=0; else misses=$((misses+1)); fi
        fi
        if [ $misses -ge 3 ]; then say "FAIL $label: app exited; last line: $(tail -1 "$OUT/$file" 2>/dev/null | cut -c1-200)"; return 1; fi
        if [ $(( $(date +%s) - t0 )) -gt 9000 ]; then say "FAIL $label: timeout"; return 1; fi
    done
}

arm acc-A || exit 1
say "cooldown ${COOL:-120}s"; sleep ${COOL:-120}
arm acc-B --expert-skip miss:0.08 || exit 1
say "ALL DONE"
