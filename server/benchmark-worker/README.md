# Benchmark results Worker

Receives the in-app benchmark's results. The app sends one `report.json` (format 2) to
`POST /v1/results`. The Worker checks it (`src/validate.ts`) and stores it as one row in a
D1 database. Nothing about the sender is stored: no address, no request log.

`GET /privacy` serves the app's privacy policy (`src/privacy.ts`), which the App Store
listing and the app's Settings link to. A change to what the app or this Worker collects
changes that page in the same commit.

| Reply | Meaning |
| --- | --- |
| 201 | Stored. |
| 409 | Already stored (same `submissionID`). The app treats it as sent. |
| 400 | Not a valid report; `field` names the first field that failed. |
| 413, 415, 429 | Over 64 KB, not JSON, or more than ten requests a minute from one address. |

## Develop

Needs Node 23.6 or later, which runs the TypeScript directly.

```bash
npm install
npm test                  # validator and handler, against a real run's report
npm run migrate:local     # once: creates the table in .wrangler/
npm run dev               # http://localhost:8787, local D1 and rate limiter
./export.sh --local out.jsonl
```

`test/fixtures/report-format2.json` is the first in-app run (2026-10-13). The Swift test
`theWorkersFixtureIsWhatTheAppWrites` decodes the same file, so a field the app adds without
the Worker learning it fails there first.

## Deploy

With a free Cloudflare account:

```bash
npx wrangler login                              # opens a browser
npx wrangler d1 create turbo-fieldfare-bench    # put the printed ID in wrangler.toml
npm run migrate:remote
npm run deploy                                  # prints the workers.dev URL
```

## Remove a result

The privacy policy promises removal to anyone who emails a report ID, which the app shows
on a sent run's screen. Delete the row; the next export leaves it out.

```bash
npx wrangler d1 execute turbo-fieldfare-bench --remote \
  --command "DELETE FROM submissions WHERE submission_id = '<report ID>'"
```

## Export

`./export.sh` writes every stored result to `benchmark-submissions/submissions.jsonl` at the
repo root, one `{"receivedAt", "report"}` object per line, oldest first. Review it and
commit it.
