#!/bin/bash
# One run of each real-generation-v1 case on the iPhone, at main f6345d1, to
# read the [gpu-time] and [read-latency] lines. Adapted from
# benchmark-results-2026-10-01-grouped-attention/run-ab.sh, which documents the
# devicectl workarounds kept here.
set -u
D=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BID=io.github.maxslamdunk.TurboFieldfareiOS
APP=${APP:?set APP to the folder holding TurboFieldfareiOS.app}
S=${TMPDIR:-/tmp}
OUT=$(cd "$(dirname "$0")" && pwd)/logs
mkdir -p "$OUT"
COOL=${COOL:-300}
say() { echo "$(date +%H:%M:%S) $*"; }

if [ -z "${NO_INSTALL:-}" ]; then
    say "install"
    xcrun devicectl device install app --device $D "$APP/TurboFieldfareiOS.app" >/dev/null 2>"$S/install.err" \
        || { say "FAIL install: $(tail -2 $S/install.err)"; exit 1; }
fi

run() {  # case label
    local case=$1 label=$2
    case " ${SKIP:-} " in *" $label "*) say "skip $label"; return 0;; esac
    say "launch $label ($case)"
    xcrun devicectl device process launch --device $D --terminate-existing $BID \
        --autorun --case $case --label $label --slots 24 --max-new 1024 --max-context 4096 \
        >/dev/null 2>"$S/launch.err" || { say "FAIL launch $label: $(tail -2 $S/launch.err)"; exit 1; }
    local t0=$(date +%s) file="" misses=0
    while true; do
        sleep 20
        file=$(xcrun devicectl device info files --device $D --domain-type appDataContainer \
            --domain-identifier $BID --subdirectory Documents 2>/dev/null \
            | awk '{print $1}' | grep "^decode-$label-.*\.log$" | tail -1)
        if [ -n "$file" ]; then
            xcrun devicectl device copy from --device $D --domain-type appDataContainer \
                --domain-identifier $BID --source "Documents/$file" --destination "$OUT/$file" >/dev/null 2>&1
            if grep -q ", generated, " "$OUT/$file" 2>/dev/null; then
                local txt=${file%.log}.txt
                xcrun devicectl device copy from --device $D --domain-type appDataContainer \
                    --domain-identifier $BID --source "Documents/$txt" --destination "$OUT/$txt" >/dev/null 2>&1
                say "done $label: $(grep ', done, ' "$OUT/$file" | sed 's/.*, \[/[/')"
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
        if [ $(( $(date +%s) - t0 )) -gt 1500 ]; then say "FAIL $label: timeout"; return 1; fi
    done
}

say "cooldown 60s"; sleep 60
run short-explanation short-1 || exit 1; say "cooldown ${COOL}s"; sleep $COOL
run medium-review medium-1 || exit 1; say "cooldown ${COOL}s"; sleep $COOL
run long-synthesis long-1 || exit 1
say "ALL DONE"
