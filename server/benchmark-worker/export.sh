#!/bin/sh
# Writes every stored result, oldest first, as one JSON object per line:
# {"receivedAt": …, "report": {…}}, without the report's submissionID: holding
# that ID is what lets a sender have their result removed, so it stays private
# to them and the database. Reads the deployed database unless the
# first argument is --local (the `wrangler dev` one).
#
#   server/benchmark-worker/export.sh [--local|--remote] [output]
set -eu
cd "$(dirname "$0")"
where=${1:---remote}
out=${2:-../../benchmark-submissions/submissions.jsonl}
mkdir -p "$(dirname "$out")"
WRANGLER_SEND_METRICS=false npx wrangler d1 execute turbo-fieldfare-bench "$where" --json \
  --command "SELECT received_at, report FROM submissions ORDER BY received_at, submission_id" |
  jq -c '.[0].results[] | {receivedAt: .received_at, report: (.report | fromjson | del(.submissionID))}' > "$out.tmp"
mv "$out.tmp" "$out"
echo "$(wc -l < "$out" | tr -d ' ') results in $out"
