#!/bin/bash
# Quality gate: --score-endpoints 16 over medium then long, one process per
# arm. A = default, B = --no-routed-tensorops. A run ends at the long case's
# endpoints-done line.
NO_INSTALL=${NO_INSTALL:-1}
DONE_RE="endpoints-done, .*case=long-synthesis" TIMEOUT=3000
. "$(dirname "$0")/lib.sh"
say "cooldown ${COOL0:-60}s"; sleep ${COOL0:-60}
run medium-review gate-A --session medium-review,long-synthesis --score-endpoints 16 || exit 1
say "cooldown ${COOL}s"; sleep $COOL
run medium-review gate-B --session medium-review,long-synthesis --score-endpoints 16 --no-routed-tensorops || exit 1
say "ALL DONE"
