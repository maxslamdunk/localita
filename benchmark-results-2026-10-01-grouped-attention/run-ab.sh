#!/bin/bash
# Grouped-attention A/B on the iPhone. A = 810068b + harness hash, B = 016270a.
set -u
D=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BID=io.github.maxslamdunk.TurboFieldfareiOS
# Built bundles: $APPS/A/TurboFieldfareiOS.app and $APPS/B/TurboFieldfareiOS.app (see status.md).
APPS=${APPS:?set APPS to the folder holding A/ and B/}
S=${TMPDIR:-/tmp}
OUT=/Users/max/ml_projects/iphone-port/turbo-fieldfare/benchmark-results-2026-10-01-grouped-attention/logs
mkdir -p "$OUT"
COOL=${COOL:-300}

say() { echo "$(date +%H:%M:%S) $*"; }

installed="${INSTALLED:-}"
run() {  # arm case label
    local arm=$1 case=$2 label=$3
    case " ${SKIP:-} " in *" $label "*) say "skip $label (done)"; skipped=1; return 0;; esac
    skipped=0
    if [ "$installed" != "$arm" ]; then
        say "install $arm"
        xcrun devicectl device install app --device $D "$APPS/$arm/TurboFieldfareiOS.app" >/dev/null 2>"$S/install.err" \
            || { say "FAIL install $arm: $(tail -2 $S/install.err)"; exit 1; }
        installed=$arm
    fi
    if [ "${ADOPT:-}" = "$label" ]; then
        say "adopt $label (already running)"
        ADOPT=""
    else
    say "launch $label ($arm $case)"
    xcrun devicectl device process launch --device $D --terminate-existing $BID \
        --autorun --case $case --label $label --slots 24 --max-new 1024 --max-context 4096 \
        >/dev/null 2>"$S/launch.err" || { say "FAIL launch $label: $(tail -2 $S/launch.err)"; exit 1; }
    fi
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
        # A listing can come back empty while the phone is busy, so only
        # three misses in a row, each from a listing that succeeded, count.
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

skipped=0
cool() { [ $skipped = 1 ] && return 0; say "cooldown ${1}s"; sleep $1; }
abort() { say "ABORT"; exit 1; }
[ -z "${ADOPT:-}" ] && cool 180

run A short-explanation short-A1 || abort; cool $COOL
run B short-explanation short-B1 || abort; cool $COOL
run B medium-review medium-B1 || abort; cool $COOL
run A medium-review medium-A1 || abort; cool $COOL
run A long-synthesis long-A1 || abort; cool $COOL
run B long-synthesis long-B1 || abort; cool $COOL
run B long-synthesis long-B2 || abort; cool $COOL
run A long-synthesis long-A2 || abort
say "ALL DONE"

say "reinstall B so the phone is left on HEAD"
xcrun devicectl device install app --device $D "$APPS/B/TurboFieldfareiOS.app" >/dev/null 2>&1 && say "B installed"
