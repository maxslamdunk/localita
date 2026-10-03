#!/bin/bash
# Waits for the harness log with the given label to finish, then copies it
# here. Usage: pull-log.sh <label>
D=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BID=io.github.maxslamdunk.TurboFieldfareiOS
OUT=$(cd "$(dirname "$0")" && pwd)/default-check
for i in $(seq 1 24); do
    sleep 15
    f=$(xcrun devicectl device info files --device $D --domain-type appDataContainer \
        --domain-identifier $BID --subdirectory Documents 2>/dev/null \
        | awk '{print $1}' | grep "^decode-$1-.*\.log$" | tail -1)
    [ -n "$f" ] || continue
    xcrun devicectl device copy from --device $D --domain-type appDataContainer \
        --domain-identifier $BID --source "Documents/$f" --destination "$OUT/$f" >/dev/null 2>&1
    if grep -q ", generated, " "$OUT/$f"; then echo "$OUT/$f"; exit 0; fi
done
echo "not finished"; exit 1
