#!/bin/bash
# Drives the 2026-11-08 read-size probe on the iPhone: install the probe app
# (~/ml_projects/iphone-port/probes/memory-ceiling), write the 12.01 GiB corpus,
# wait 300 s, then run `iosize` (3,358,720 / 1,769,472 / 884,736 B, A B C C B A,
# 60 s each, F_NOCACHE). Logs land in logs/ beside this script.
#
# usage: run.sh <path to MemoryCeilingProbe.app>

set -u
DEVICE=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BUNDLE=io.github.maxslamdunk.MemoryCeilingProbe
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$1"
mkdir -p "$DIR/logs"

copy_logs() {
    xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source Documents --destination "$DIR/logs/" >/dev/null 2>&1
}

# Waits until the newest log for <label> contains <done-event> or a failure row.
wait_for() {
    local label="$1" done_event="$2" timeout="$3" start log
    start=$(date +%s)
    while true; do
        sleep 15
        copy_logs
        log=$(ls -t "$DIR"/logs/*"-$label-"*.log 2>/dev/null | head -1)
        if [ -n "$log" ] && grep -q -E "$done_event|failed|io-no-corpus|io-read-short" "$log"; then
            echo "$label finished after $(( $(date +%s) - start ))s: $log"
            tail -3 "$log"
            return 0
        fi
        if [ $(( $(date +%s) - start )) -gt "$timeout" ]; then
            echo "$label still running after ${timeout}s"
            return 1
        fi
    done
}

echo "install at $(date '+%H:%M:%S')"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null || { echo "install failed"; exit 1; }

echo "ioprep at $(date '+%H:%M:%S')"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    "$BUNDLE" --mode ioprep --label prep1108 >/dev/null || { echo "launch failed"; exit 1; }
wait_for prep1108 io-prep-done 900 || exit 1

echo "cooldown 300 s from $(date '+%H:%M:%S')"
sleep 300

echo "iosize at $(date '+%H:%M:%S')"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
    "$BUNDLE" --mode iosize --label size1108 >/dev/null || { echo "launch failed"; exit 1; }
wait_for size1108 io-size-done 600 || exit 1
echo "done at $(date '+%H:%M:%S')"
