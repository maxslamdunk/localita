#!/bin/bash
# Arm B of the second gate stopped at endpoint 19 of 24 when the phone was
# restarted (00:25). Rerun B on the long case only; gate.py merges the logs.
NO_INSTALL=1 DONE_RE="endpoints-done, .*case=long-synthesis" TIMEOUT=3600
. "$(dirname "$0")/lib.sh"
say "cooldown ${COOL0:-120}s"; sleep ${COOL0:-120}
run long-synthesis gate2-B-r2 --session long-synthesis --score-endpoints 12 --score-continuation --no-routed-tensorops || exit 1
say "ALL DONE"
