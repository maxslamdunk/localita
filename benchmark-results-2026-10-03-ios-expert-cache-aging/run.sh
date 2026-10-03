#!/bin/bash
# Expert-cache count aging A/B on the iPhone, as a session: 11 prompts back to
# back in one process (`--session`), each from an empty KV like a new chat.
# Same binary; A = --no-expert-cache-aging (LFU counts kept for the model's
# lifetime, today), B = --expert-cache-aging. A B B A, 300 s cooldowns.
# Defaults otherwise (early read with the fitted guess, F_NOCACHE), 24 slots,
# --max-new 512 per prompt, --max-context 4096, chunk auto. --model-dir pins
# gemma4: the app's remembered model was supergemma4 on the day, and a pinned
# folder is not remembered over it.
# Adapted from benchmark-results-2026-10-03-ios-expert-read-nocache/run.sh.
set -u
D=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BID=io.github.maxslamdunk.TurboFieldfareiOS
APP=${APP:?set APP to the folder holding TurboFieldfareiOS.app}
S=${TMPDIR:-/tmp}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/logs
mkdir -p "$OUT"
COOL=${COOL:-300}
# The order session.py and reset_decay.py replay (seed 0).
SESSION=val-logic-grid,val-rust-borrow,val-sql-debug,val-es-recipe,val-compare-table,val-fr-translate,val-multi-turn,short-explanation,medium-review,long-synthesis,val-dialogue
say() { echo "$(date +%H:%M:%S) $*"; }

if [ -z "${NO_INSTALL:-}" ]; then
    say "install"
    xcrun devicectl device install app --device $D "$APP/TurboFieldfareiOS.app" >/dev/null 2>"$S/install.err" \
        || { say "FAIL install: $(tail -2 $S/install.err)"; exit 1; }
fi

# The val prompts beside the frozen real-generation-v1 files already there.
for f in "$HERE"/prompts/*.json; do
    xcrun devicectl device copy to --device $D --domain-type appDataContainer \
        --domain-identifier $BID --source "$f" --destination "Documents/prompts/$(basename "$f")" \
        >/dev/null 2>"$S/push.err" || { say "FAIL push $(basename "$f"): $(tail -2 $S/push.err)"; exit 1; }
done
say "prompts pushed"

run() {  # label [extra launch args]
    local label=$1; shift
    case " ${SKIP:-} " in *" $label "*) say "skip $label"; return 0;; esac
    say "launch $label"
    xcrun devicectl device process launch --device $D --terminate-existing $BID \
        --autorun --model-dir gemma4.gturbo --session $SESSION --label $label \
        --slots 24 --max-new 512 --max-context 4096 "$@" \
        >/dev/null 2>"$S/launch.err" || { say "FAIL launch $label: $(tail -2 $S/launch.err)"; exit 1; }
    local t0=$(date +%s) file="" misses=0 listing
    while true; do
        sleep 30
        listing=$(xcrun devicectl device info files --device $D --domain-type appDataContainer \
            --domain-identifier $BID --subdirectory Documents 2>/dev/null | awk '{print $1}')
        file=$(echo "$listing" | grep "^decode-$label-.*\.log$" | tail -1)
        if [ -n "$file" ]; then
            xcrun devicectl device copy from --device $D --domain-type appDataContainer \
                --domain-identifier $BID --source "Documents/$file" --destination "$OUT/$file" >/dev/null 2>&1
            if grep -q ", session-done, " "$OUT/$file" 2>/dev/null; then
                for txt in $(echo "$listing" | grep "^${file%.log}-.*\.txt$"); do
                    xcrun devicectl device copy from --device $D --domain-type appDataContainer \
                        --domain-identifier $BID --source "Documents/$txt" --destination "$OUT/$txt" >/dev/null 2>&1
                done
                say "done $label: $(grep -c ', done, ' "$OUT/$file") cases"
                return 0
            fi
        fi
        local procs
        if procs=$(xcrun devicectl device info processes --device $D 2>/dev/null); then
            if echo "$procs" | grep -q '/TurboFieldfareiOS.app/TurboFieldfareiOS'; then misses=0; else misses=$((misses+1)); fi
        fi
        if [ $misses -ge 3 ]; then
            sleep 5
            say "FAIL $label: app exited without finishing; last line: $(tail -1 "$OUT/$file" 2>/dev/null | cut -c1-200)"
            return 1
        fi
        if [ $(( $(date +%s) - t0 )) -gt 4200 ]; then say "FAIL $label: timeout"; return 1; fi
    done
}

say "cooldown 60s"; sleep 60
first=1
for arm in A1 B1 B2 A2; do
    [ $first -eq 1 ] || { say "cooldown ${COOL}s"; sleep $COOL; }
    first=0
    case $arm in
        A*) run sess-$arm --no-expert-cache-aging || exit 1;;
        B*) run sess-$arm --expert-cache-aging || exit 1;;
    esac
done
say "ALL DONE"
