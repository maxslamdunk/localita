#!/bin/bash
# Phone check: long, hashed load, defaults, two runs with cooldowns. Uses
# step 3's driver (lib.sh); finished labels are skipped.
. "$(dirname "$0")/../benchmark-results-2026-11-06-ios-prefill-layer-major/lib.sh"
first=1
for label in ${RUNS:-resume-A1 resume-A2}; do
    if finished $label; then say "skip $label (already in logs/)"; continue; fi
    if [ $first -eq 1 ]; then say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
    else say "cooldown ${COOL}s"; sleep $COOL; fi
    first=0
    run long-synthesis $label || exit 1
done
say "ALL DONE"
