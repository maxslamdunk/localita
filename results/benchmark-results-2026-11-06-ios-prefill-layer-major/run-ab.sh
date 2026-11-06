#!/bin/bash
# A = default (layer at a time), B = --no-layer-major-prefill. Long A B B A,
# then medium A B B A as the control (one chunk on iOS); --max-new 32, only
# prefill changes. Finished labels are skipped, cooldown included.
. "$(dirname "$0")/lib.sh"
first=1
for spec in ${RUNS:-long-synthesis:long-A1:A long-synthesis:long-B1:B long-synthesis:long-B2:B long-synthesis:long-A2:A medium-review:medium-A1:A medium-review:medium-B1:B medium-review:medium-B2:B medium-review:medium-A2:A}; do
    case=${spec%%:*} rest=${spec#*:} label=${rest%%:*} arm=${rest##*:}
    if finished $label; then say "skip $label (already in logs/)"; continue; fi
    if [ $first -eq 1 ]; then say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
    else say "cooldown ${COOL}s"; sleep $COOL; fi
    first=0
    if [ "$arm" = B ]; then run $case $label --no-layer-major-prefill || exit 1
    else run $case $label || exit 1; fi
done
say "ALL DONE"
