#!/usr/bin/env python3
"""Writes the 50 phone prompt files for the expert-skip accuracy check.

GSM-Symbolic P2 (apple/GSM-Symbolic, p2/test.jsonl, CC BY-NC-ND 4.0) is not
committed here: download it and pass its path. The selection is instance 0 of
each of the 50 templates, as the paper groups one evaluation set. The prompt
files go to OUTDIR, outside the repo, and are pushed to the phone.

usage: make_prompts.py P2_TEST_JSONL OUTDIR
"""
import hashlib, json, os, sys

P2_SHA256 = "00496e6c36bd746d56b28cffcd9385f78f0568a5fe1543650ddf9b55d398251c"
INSTRUCTION = ("Solve the following problem. Work step by step, then give the final answer "
               "as a number on its own last line, as `Final answer: <number>`.\n\n")

def selected(path):
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != P2_SHA256:
        sys.exit(f"{path}: SHA-256 differs from {P2_SHA256}")
    rows = [json.loads(line) for line in data.decode().splitlines() if line.strip()]
    picked = sorted((r for r in rows if r["instance"] == 0), key=lambda r: r["id"])
    assert [r["id"] for r in picked] == list(range(50))
    return picked

def case_id(row):
    return f"gsmp2-{row['id']:02d}"

if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for row in selected(src):
        with open(os.path.join(out, case_id(row) + ".json"), "w") as f:
            json.dump([{"role": "user", "content": INSTRUCTION + row["question"]}], f, ensure_ascii=False)
    print(",".join(case_id(r) for r in selected(src)))
