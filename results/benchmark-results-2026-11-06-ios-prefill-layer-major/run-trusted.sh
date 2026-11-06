#!/bin/bash
# Trusted load (--trust-install): A = default, B = --no-layer-major-prefill.
# Long A B B A; --max-new 32, only
# prefill changes. Finished labels are skipped, cooldown included.
. "$(dirname "$0")/lib.sh"
first=1
for spec in ${RUNS:-long-synthesis:trust-A1:A long-synthesis:trust-B1:B long-synthesis:trust-B2:B long-synthesis:trust-A2:A}; do
    case=${spec%%:*} rest=${spec#*:} label=${rest%%:*} arm=${rest##*:}
    if finished $label; then say "skip $label (already in logs/)"; continue; fi
    if [ $first -eq 1 ]; then say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
    else say "cooldown ${COOL}s"; sleep $COOL; fi
    first=0
    if [ "$arm" = B ]; then run $case $label --trust-install --no-layer-major-prefill || exit 1
    else run $case $label --trust-install || exit 1; fi
done
say "ALL DONE"
