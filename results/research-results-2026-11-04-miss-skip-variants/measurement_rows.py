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
SEE = "See `results/research-results-2026-11-04-miss-skip-variants/results.md`."


def rows():
    out = []
    for path in glob.glob(os.path.join(HERE, "logs", "*.txt")):
        name = os.path.basename(path)[:-4]
        text = open(path).read()
        head = re.search(r"^# (\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) commit (\S+)", text, re.M)
        env = re.search(r"env: (.*)", text)[1].strip() or "none (unchanged runtime)"
        sha = head[3] if head[3] == "fa5cc90" else f"{head[3]} (binary built at fa5cc90; no code change since)"
        if name == "ref-disk-full":
            notes = (f"`ref`, first attempt: env `{env}`. **Crashed**: `NSFileHandleOperationException`, "
                     "\"No space left on device\", while writing the reference file; no result. Re-run as `ref`. "
                     + SEE)
            out.append((head[1], head[2], f"| {head[1]} | {sha} | {HOST}; {SCORE} | ? | ? | n/a | ? | {notes} |"))
            continue
        io = re.search(r"^decode: .*fg reads/tok ([\d.]+), early reads/tok ([\d.]+), MiB/tok ([\d.]+), "
                       r"hit ([\d.]+)%", text, re.M)
        total = re.search(r"^TOTAL: .*$", text, re.M)
        ref = re.search(r"^reference: .*$", text, re.M)
        skip = re.search(r"^skip: .*$", text, re.M)
        notes = f"`{name}`: env `{env}`. "
        if name == "ref":
            notes += "Reference (unchanged runtime). Its reference file is byte-identical to 2026-10-04's (`cmp`). "
        notes += (total[0].replace("TOTAL: ", "") if total else ref[0]) + ". "
        notes += f"Foreground reads/tok {io[1]}, early {io[2]}. "
        if skip:
            notes += skip[0] + ". "
        notes += SEE
        out.append((head[1], head[2], f"| {head[1]} | {sha} | {HOST}; {SCORE} | {io[3]} MiB | {io[4]}% | n/a | ? "
                                      f"| {notes} |"))
    out.sort()
    return [r for _, _, r in out]


if __name__ == "__main__":
    print("\n".join(rows()))
