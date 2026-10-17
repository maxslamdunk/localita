#!/bin/zsh
set -u
# Drives `--background-generation-check` on the iPhone 17: installs the current
# Release build over the app, starts one long reply in the chat UI, launches the
# Settings app over it once 40 tokens are out (which backgrounds the app and
# should open the Picture in Picture window), comes back after AWAY seconds
# (default 45), and pulls the check log and app-memory.log next to this script
# (or into $OUT). The phone must be unlocked. SKIP_INSTALL=1 skips the install.
DEV=42F93595-A5B1-5E99-94A2-DF741A8D78F0
BID=io.github.maxslamdunk.TurboFieldfareiOS
OUT=${OUT:-${0:A:h}}
cd /Users/max/ml_projects/iphone-port/turbo-fieldfare
APP=$(xcodebuild -project iOS/TurboFieldfareiOS.xcodeproj -scheme TurboFieldfareiOS -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/TurboFieldfareiOS.app
fetch() {
  local name
  name=$(xcrun devicectl device info files --device $DEV --domain-type appDataContainer --domain-identifier $BID --subdirectory Documents 2>/dev/null | grep -oE 'decode-background-generation-[0-9TZ:-]+\.log' | sort | tail -1)
  [ -n "$name" ] || return 1
  xcrun devicectl device copy from --device $DEV --domain-type appDataContainer --domain-identifier $BID --source "Documents/$name" --destination "$OUT/check.log" >/dev/null 2>&1
}
if [ "${SKIP_INSTALL:-0}" != 1 ]; then
  echo "$(date -u +%T) install"; xcrun devicectl device install app --device $DEV "$APP" 2>&1 | tail -1
fi
echo "$(date -u +%T) launch check"
launched=$(xcrun devicectl device process launch --device $DEV --terminate-existing $BID --background-generation-check 2>&1)
echo "$launched" | tail -1
if ! echo "$launched" | grep -q "Launched application"; then
  echo "launch failed (is the phone unlocked?)"; exit 1
fi
sleep 20
for i in {1..60}; do
  sleep 10
  fetch || continue
  last=$(grep -E 'progress|abort|turn-ended' "$OUT/check.log" | tail -1)
  echo "$(date -u +%T) $last" | cut -c1-200
  echo "$last" | grep -qE 'abort|turn-ended' && break
  tok=$(echo "$last" | grep -oE 'tokens=[0-9]+' | cut -d= -f2)
  [ -n "$tok" ] && [ "$tok" -ge 40 ] && break
done
echo "$(date -u +%T) launch Settings over it"; xcrun devicectl device process launch --device $DEV com.apple.Preferences 2>&1 | tail -1
sleep ${AWAY:-45}
fetch; echo "--- while away:"; grep -E 'progress' "$OUT/check.log" | tail -3 | cut -c1-220
echo "$(date -u +%T) back to the app"; xcrun devicectl device process launch --device $DEV $BID 2>&1 | tail -1
for i in {1..90}; do
  sleep 10
  fetch || continue
  grep -qE 'done|abort' "$OUT/check.log" && break
done
fetch
xcrun devicectl device copy from --device $DEV --domain-type appDataContainer --domain-identifier $BID --source Documents/app-memory.log --destination "$OUT/app-memory.log" >/dev/null 2>&1
echo "$(date -u +%T) finished"
