#!/bin/bash
# supergemma4 guess A/B on the iPhone: same binary, supergemma4 pinned with
# --model-dir, early read on in both arms. N = the next layer's router
# (--early-expert-guess router), F = the default, which loads the fitted file
# the runtime ships for supergemma4 (gemma4's, by index.json). Each case
# N F F N. Labels carry an sg4 prefix so the poll never matches an older
# run's log in Documents. Adapted from
# benchmark-results-2026-10-03-ios-fitted-guess/run.sh.
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

run() {  # case label [extra launch args]
    local case=$1 label=$2; shift 2
    case " ${SKIP:-} " in *" $label "*) say "skip $label"; return 0;; esac
    say "launch $label ($case)"
    xcrun devicectl device process launch --device $D --terminate-existing $BID \
        --autorun --model-dir supergemma4.gturbo --case $case --label $label --slots 24 --max-new 1024 --max-context 4096 "$@" \
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
first=1
for c in short-explanation:sg4short medium-review:sg4medium long-synthesis:sg4long; do
    case=${c%%:*} n=${c##*:}
    for arm in N1 F1 F2 N2; do
        # A skipped run needs no cooldown before it.
        case " ${SKIP:-} " in *" $n-$arm "*) say "skip $n-$arm"; continue;; esac
        [ $first -eq 1 ] || { say "cooldown ${COOL}s"; sleep $COOL; }
        first=0
        case $arm in
            N*) run $case $n-$arm --early-expert-read --early-expert-guess router || exit 1;;
            F*) run $case $n-$arm --early-expert-read || exit 1;;
        esac
    done
done
say "ALL DONE"
