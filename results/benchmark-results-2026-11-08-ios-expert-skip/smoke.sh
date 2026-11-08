#!/bin/bash
# Installs the build, then a 16-token B run, to check that --expert-skip
# reaches the runtime before the A/B. Its log is moved to smoke/.
. "$(dirname "$0")/lib.sh"
MAXNEW=16 run short-explanation smoke-B --expert-skip miss:0.08 || exit 1
mkdir -p "$OUT/../smoke" && mv "$OUT"/decode-smoke-B-* "$OUT/../smoke/"
