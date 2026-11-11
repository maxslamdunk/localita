#!/usr/bin/env python3
"""Prints the MEASUREMENTS.md rows for the sweep, one per run and case.

    python3 results/benchmark-results-2026-11-10-ios-settings-sweep/measurement_rows.py \
        benchmark-submissions/submissions.jsonl
"""
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from summarize import CASES, load, parse  # noqa: E402

SHA = "c414fa3"


def skip_name(t):
    return "off" if not t else f"`miss:{t:g}`".replace("miss:0.1`", "miss:0.10`")


def stamp(t):
    return datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ")


def main():
    runs = load(sys.argv[1])
    previous = None
    for r in runs:
        wait = f"{(stamp(r['started']) - stamp(previous)).total_seconds():.0f} s after the previous run" if previous else "first run"
        previous = r["finished"]
        i = r["sweep"]["index"]
        s = r["settings"]
        dev = r["device"]
        slots = s["expertCacheSlots"]
        skip = float(s.get("expertSkipThreshold") or 0.0)
        for c in r["cases"]:
            d = parse(c)
            cid = c["caseID"]
            peak = f"{d['peak']:.3f} GB (process peak since launch"
            peak += ", carried from run 2)" if i > 2 else ")"
            config = (
                f"iPhone 18 Pro (`{dev['identifier']}`), 12 GB, iOS {dev['osVersion']}; a tester's phone, "
                f"capacity unknown; app {dev['appVersion']} from `{SHA}` (report format {r['format']}); "
                f"**in-app settings sweep** `{r['sweep']['id']}`, run {i} of 7, unattended on a charger; "
                f"**{slots} slots, skip {skip_name(skip)}**; bundled fitted guess, one early read, "
                f"`F_NOCACHE`, count aging; LFU, max-new 1024, max-context 4096, prefill chunk `auto`, "
                f"T 0.2 / Top-K 64 / Top-P 0.95, seed 1; each case from a fresh model load; "
                f"case cooldown {d['cool']:.0f} s ({wait}), log `{c['logFile']}`; battery {dev['batteryAtStart']} at run start"
            )
            notes = (
                f"`real-generation-v1` `{cid}`: stop={d['stop']}, new {d['tokens']} tok, text SHA-256 "
                f"`{d['sha'][:8]}…`. reads/tok {d['reads']:.2f}, early reads {d['early']:.2f}/tok, used "
                f"{d['used']:.2f}, foreground {d['fg']:.2f}. `io` {d['io']:.2f}, `cb1-wait` {d['cb1w']:.2f}, "
                f"head {d['head']:.2f}, wall {d['wall']:.2f}; GPU attention+router {d['g_cb1']:.2f}, GPU "
                f"shared {d['g_shared']:.2f}, GPU head {d['g_head']:.2f}, busy {d['g_busy']:.2f}; decode "
                f"read mean {d['read_mean']:.2f} ms; prefill {d['prefill_s']:.1f} s, {d['prefill_mb']:.2f} MB. "
                f"Peak footprint {peak}; available {d['avail']:.3f} GB. Prompt SHA-256 matches. Scored in "
                f"`results/benchmark-results-2026-11-10-ios-settings-sweep/results.md`. "
                f"Report `{r['id']}` in `benchmark-submissions/submissions.jsonl`."
            )
            print(
                f"| 2026-11-11 | {SHA} | {config} | {d['mib']:.2f} MB | {d['hit']:.1f}% | "
                f"{d['tps']:.3f} | {c['thermalAtStart']} → {c['thermalAtEnd']} (start/end only) | {notes} |"
            )


if __name__ == "__main__":
    main()
