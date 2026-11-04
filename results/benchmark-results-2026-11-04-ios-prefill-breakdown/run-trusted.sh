#!/bin/bash
# Prefill breakdown, --trust-install arm (profiling, not speed). Adapted
# from benchmark-results-2026-10-08-ios-early-read-x2/run.sh.
set -u
D=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BID=io.github.maxslamdunk.Localita
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
    # A launch can fail on a dropped devicectl connection (NWError 54,
    # 2026-10-08); retry before giving up.
    local attempt
    for attempt in 1 2 3; do
        xcrun devicectl device process launch --device $D --terminate-existing $BID \
            --autorun --case $case --label $label --slots 24 --max-new ${MAXNEW:-32} --max-context 4096 "$@" \
            >/dev/null 2>"$S/launch.err" && break
        [ $attempt -lt 3 ] || { say "FAIL launch $label: $(tail -2 $S/launch.err)"; exit 1; }
        say "launch $label failed (attempt $attempt): $(grep -m1 -o 'NWError[^)]*)\|error[^.]*' $S/launch.err)"; sleep 20
    done
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

# Second set: the same cases with --trust-install, so no layer file is
# SHA-256 hashed on first touch. Against run.sh's plain runs this prices the
# hashing that every iOS load does today. Modes: p = --prefill-profile,
# t = --trust-install.
say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
first=1
for spec in ${RUNS:-medium-review:medium-trust:t long-synthesis:long-trust:t long-synthesis:long-trust-prof:pt}; do
    case=${spec%%:*} rest=${spec#*:} label=${rest%%:*} mode=${rest##*:}
    [ $first -eq 1 ] || { say "cooldown ${COOL}s"; sleep $COOL; }
    first=0
    extra=()
    case $mode in *p*) extra+=(--prefill-profile);; esac
    case $mode in *t*) extra+=(--trust-install);; esac
    run $case $label "${extra[@]}" || exit 1
done
say "ALL DONE"
