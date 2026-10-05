#!/usr/bin/env python3
"""Print MEASUREMENTS.md rows for every real-model run in this study, from
the logs, in run order. Appended once by hand; kept for the record."""
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = "M1 MacBook Air 8 GB, macOS 26.6.1"
SCORE = ("`TurboFieldfareScore` teacher-forced quality meter (research run, timing not a benchmark): "
         "12 transcripts × 128 tokens = 1,536 positions, `sequences.json`; 24 slots, early read on "
         "(fitted guess), count aging on, prefill chunk 256")


def score_rows():
    rows = []
    for path in glob.glob(os.path.join(HERE, "logs", "*.txt")):
        name = os.path.basename(path)[:-4]
        if name.startswith("smoke") or name.startswith("queue"):
            continue
        text = open(path).read()
        head = re.search(r"^# (\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) commit (\S+)", text, re.M)
        env = re.search(r"env: (.*)", text)[1].strip() or "none (unchanged runtime)"
        io = re.search(r"fg reads/tok ([\d.]+), early reads/tok ([\d.]+), MiB/tok ([\d.]+), hit ([\d.]+)%", text)
        total = re.search(r"^TOTAL: .*$", text, re.M)
        ref = re.search(r"^reference: .*$", text, re.M)
        skip = re.search(r"^skip: .*$", text, re.M)
        if name == "all2-stopped":
            done = len(re.findall(r"^seq ", text, re.M))
            notes = (f"`{name}`: env `{env}`. **Stopped at the user's request** after {done} of 12 transcripts; "
                     "no result. See `research-results-2026-10-04-lossy-experts/results.md`.")
            rows.append((head[1], head[2], head[3], "?", "?", notes))
            continue
        if name.endswith("-refmode"):
            what = ("**Not scored**: a `score.sh` bug ran it in reference-writing mode, so only its read counts "
                    "are usable; re-run as `" + name[:-8] + "`. ")
        elif name in ("ref", "ref-again"):
            what = "Reference (unchanged runtime). " + (
                "Its reference file is byte-identical to `ref`'s (`cmp`), so the meter is deterministic. "
                if name == "ref-again" else "")
        else:
            what = ""
        notes = f"`{name}`: env `{env}`. {what}"
        if total:
            notes += total[0].replace("TOTAL: ", "") + ". "
        elif ref:
            notes += ref[0] + ". "
        notes += f"Foreground reads/tok {io[1]}, early {io[2]}. "
        if skip:
            notes += skip[0] + ". "
        notes += "See `research-results-2026-10-04-lossy-experts/results.md`."
        rows.append((head[1], head[2], head[3], f"{io[3]} MiB", f"{io[4]}%", notes))
    rows.sort(key=lambda r: (r[0], r[1]))
    out = []
    for date, _, sha, mib, hit, notes in rows:
        sha = sha.replace("+dirty", "-dirty")
        if sha == "da57c46-dirty":
            sha = "da57c46-dirty (binary built at 99841bb)"
        out.append(f"| {date} | {sha} | {HOST}; {SCORE} | {mib} | {hit} | n/a | ? | {notes} |")
    return out


def gen_rows():
    out = []
    for path in sorted(glob.glob(os.path.join(HERE, "gen", "*.err"))):
        name = os.path.basename(path)[:-4]
        text = open(path).read()
        stop = re.search(r"^\[stop=(\S+) prefill=(\d+)tok new=(\d+)tok decode=([\d.]+)s tok/s=([\d.]+)\]", text, re.M)
        io = re.search(r"bytes/tok=([\d.]+)MB hit-rate=([\d.]+)% req/tok=[\d.]+ reads/tok=([\d.]+)", text)
        phase = re.search(r"^\[phase-time.*$", text, re.M)[0]
        cb1w = re.search(r"cb1-wait=([\d.]+)", phase)[1]
        iot = re.search(r" io=([\d.]+)", phase)[1]
        wall = re.search(r"wall=([\d.]+)", phase)[1]
        label, case = name.split("-", 1)
        skip = {"base": "off", "miss08": "`miss:0.08`", "miss10": "`miss:0.10`"}[label]
        notes = (f"Generation for reading, **not a clean A/B** (runs back to back on a Mac at ~20% free memory and "
                 f"6 GB swap; `cb1-wait` varied 63–132 ms between runs). `real-generation-v1` {case}, expert skip "
                 f"{skip}, greedy (`--temperature 0`), `--max-new 600`, stop={stop[1]}, prefill {stop[2]} / new "
                 f"{stop[3]} tok. reads/tok {io[3]} (early 29.00). `io` {iot}, `cb1-wait` {cb1w}, wall {wall} ms/fwd. "
                 "Text in `research-results-2026-10-04-lossy-experts/gen/`.")
        cfg = (f"{HOST}; `TurboFieldfareCLI` at 63a1f08, 24 slots, 4K context, early read on, count aging on, "
               f"T 0 (greedy)")
        out.append(f"| 2026-10-05 | 63a1f08 | {cfg} | {io[1]} MB | {io[2]}% | {stop[5]} | ? | {notes} |")
    return out


if __name__ == "__main__":
    print("\n".join(score_rows() + gen_rows()))
