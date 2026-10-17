#!/bin/bash
# Pulls the default-settings run's text and prints its configuration and footers.
cd "$(dirname "$0")"
f=$(ls decode-nocache-default-*.log | tail -1)
D=42F93595-A5B1-5E99-94A2-DF741A8D78F0
xcrun devicectl device copy from --device $D --domain-type appDataContainer \
    --domain-identifier io.github.maxslamdunk.TurboFieldfareiOS \
    --source "Documents/${f%.log}.txt" --destination "${f%.log}.txt" >/dev/null 2>&1
shasum -a 256 "${f%.log}.txt" | cut -c1-8
grep -o -E "expertReadNoCache=[a-z]+|earlyExpertGuess=[^ ]{0,60}" "$f"
grep -o -E "\[(expert-io|phase-time|gpu-time|read-latency) decode [^|]*|tok/s=[0-9.]+" "$f" | cut -c1-260
grep -o -E "thermal=[a-z]+ battery=[^ ]+" "$f" | sort | uniq -c
