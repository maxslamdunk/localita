#!/bin/bash
# Second quality gate: endpoints inside each case's frozen October reply
# (--score-continuation), 12 per case, one process per arm. Installs the
# build, then pushes <case>-continuation.txt into the app's Documents.
DONE_RE="endpoints-done, .*case=long-synthesis" TIMEOUT=3600
. "$(dirname "$0")/lib.sh"
REF=$(cd "$(dirname "$0")/../benchmark-results-2026-10-08-ios-early-read-x2/logs" && pwd)
for c in long-synthesis:long medium-review:medium; do
    src=$(ls "$REF"/decode-${c##*:}-A1-*.txt)
    xcrun devicectl device copy to --device $D --domain-type appDataContainer --domain-identifier $BID \
        --source "$src" --destination "Documents/${c%%:*}-continuation.txt" >/dev/null 2>"$S/copy.err" \
        || { say "FAIL push ${c%%:*}: $(tail -2 $S/copy.err)"; exit 1; }
    say "pushed ${c%%:*}-continuation.txt ($(shasum -a 256 "$src" | cut -c1-16))"
done
say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
run medium-review gate2-A --session medium-review,long-synthesis --score-endpoints 12 --score-continuation || exit 1
say "cooldown ${COOL}s"; sleep $COOL
run medium-review gate2-B --session medium-review,long-synthesis --score-endpoints 12 --score-continuation --no-routed-tensorops || exit 1
say "ALL DONE"
