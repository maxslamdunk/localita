#!/bin/bash
# A = default (routed experts on the matrix units), B = --no-routed-tensorops.
# Long and medium A B B A, short A B; --max-new 32 (only prefill changes).
. "$(dirname "$0")/lib.sh"
say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
first=1
for spec in ${RUNS:-long-synthesis:long-A1:A long-synthesis:long-B1:B long-synthesis:long-B2:B long-synthesis:long-A2:A medium-review:medium-A1:A medium-review:medium-B1:B medium-review:medium-B2:B medium-review:medium-A2:A short-explanation:short-A1:A short-explanation:short-B1:B}; do
    case=${spec%%:*} rest=${spec#*:} label=${rest%%:*} arm=${rest##*:}
    [ $first -eq 1 ] || { say "cooldown ${COOL}s"; sleep $COOL; }
    first=0
    if [ "$arm" = B ]; then run $case $label --no-routed-tensorops || exit 1
    else run $case $label || exit 1; fi
done
say "ALL DONE"
