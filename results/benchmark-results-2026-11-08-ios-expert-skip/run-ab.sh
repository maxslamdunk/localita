#!/bin/bash
# A = defaults, B = --expert-skip miss:0.08. Each case A B B A, short then
# medium then long, --max-new 1024. Finished labels are skipped, cooldown
# included, so a rerun resumes.
. "$(dirname "$0")/lib.sh"
first=1
for c in ${CASES:-short-explanation:short medium-review:medium long-synthesis:long}; do
    case=${c%%:*} n=${c##*:}
    for arm in A1 B1 B2 A2; do
        label=$n-$arm
        if finished $label; then say "skip $label (already in logs/)"; continue; fi
        if [ $first -eq 1 ]; then say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
        else say "cooldown ${COOL}s"; sleep $COOL; fi
        first=0
        case $arm in
            A*) run $case $label || exit 1;;
            B*) run $case $label --expert-skip miss:0.08 || exit 1;;
        esac
    done
done
say "ALL DONE"
