"""Score the benchmark models against each other question by question.

Usage: paired.py <results dir> [label ...]   (default labels: original qat default)

For each run it checks that every label saw byte-identical prompts (lm-eval's
prompt_hash), then prints each label's accuracy, and for each pair the paired
difference with a 95% interval, the discordant counts and an exact McNemar
p-value. It also counts replies with no extractable answer, which separate a
model that answers wrong from one that runs out of tokens or loses the format.
"""
import json
import math
import sys
from itertools import combinations

out_dir = sys.argv[1]
labels = sys.argv[2:] or ["original", "qat", "default"]
RUNS = {"mmlu_pro": "custom-extract", "gsm8k": "strict-match"}


def load(label, run, filt):
    rows = {}
    with open(f"{out_dir}/{label}-{run}-samples.jsonl") as f:
        for line in f:
            r = json.loads(line)
            if r["filter"] != filt:
                continue
            fr = r["filtered_resps"]
            answer = fr[0] if isinstance(fr, list) else fr
            rows[(r["task"], r["doc_id"])] = (r["exact_match"], r["prompt_hash"],
                                              answer in ("[invalid]", "", None))
    return rows


def mcnemar_p(b, c):
    n, k = b + c, min(b, c)
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


for run, filt in RUNS.items():
    data = {label: load(label, run, filt) for label in labels}
    keys = sorted(set.intersection(*(set(d) for d in data.values())))
    n = len(keys)
    mismatched = sum(len({data[label][k][1] for label in labels}) > 1 for k in keys)
    print(f"== {run} ({filt}): {n} questions in common; prompts differ on {mismatched}")
    for label in labels:
        acc = sum(data[label][k][0] for k in keys) / n
        invalid = sum(data[label][k][2] for k in keys)
        print(f"  {label:9s} {100 * acc:6.2f}%   no answer extracted: {invalid}")
    for a, b in combinations(labels, 2):
        wins = sum(data[a][k][0] > data[b][k][0] for k in keys)
        losses = sum(data[a][k][0] < data[b][k][0] for k in keys)
        diff = (wins - losses) / n
        se = math.sqrt(max(wins + losses - (wins - losses) ** 2 / n, 0)) / n
        print(f"  {a} - {b}: {100 * diff:+.2f} pts (95% {100 * (diff - 1.96 * se):+.2f} to "
              f"{100 * (diff + 1.96 * se):+.2f}); {a} only right {wins}, {b} only right {losses}; "
              f"McNemar p = {mcnemar_p(wins, losses):.3g}")
