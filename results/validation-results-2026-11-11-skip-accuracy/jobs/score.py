"""Score the skip-accuracy arms: paired differences against off, with 95%
intervals and exact McNemar tests, no-answer counts, prompt identity and the
simulated cache counters.

Usage: score.py <arms dir> [<vLLM samples dir>]

<arms dir> holds eval.py's <label>-<run>-samples.jsonl and -cache.json files.
The vLLM directory, if given, holds the QAT study's default-<run>-samples.jsonl
for the same model, compared with the off arm.
"""
import json
import math
import os
import sys

ARMS = ["off", "0.08", "0.10"]
RUNS = {"mmlu_pro": "custom-extract", "gsm8k": "strict-match"}


def load(path, filt):
    """{(task, doc_id): (correct, no answer, prompt hash, new tokens)} for one filter."""
    out = {}
    for line in open(path):
        r = json.loads(line)
        if r["filter"] != filt:
            continue
        resp = r["filtered_resps"][0]
        resp = resp[0] if isinstance(resp, list) else resp
        out[(r["task"], r["doc_id"])] = (float(r["exact_match"]), resp == "[invalid]",
                                         r["prompt_hash"], (r.get("cache") or {}).get("new_tokens"))
    return out


def mcnemar(b, c):
    """Two-sided exact McNemar p: binomial(b + c, 1/2)."""
    n, k = b + c, min(b, c)
    if n == 0:
        return 1.0
    p = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * p)


def paired(a, b):
    """b − a in points over the shared questions, 95% interval, McNemar."""
    keys = sorted(set(a) & set(b))
    d = [b[k][0] - a[k][0] for k in keys]
    n = len(d)
    mean = sum(d) / n
    sd = math.sqrt(sum((x - mean) ** 2 for x in d) / (n - 1))
    half = 1.96 * sd / math.sqrt(n)
    gain, loss = sum(x > 0 for x in d), sum(x < 0 for x in d)
    return dict(n=n, diff=100 * mean, lo=100 * (mean - half), hi=100 * (mean + half),
                gained=gain, lost=loss, p=mcnemar(gain, loss))


def main():
    arms_dir = sys.argv[1]
    vllm_dir = sys.argv[2] if len(sys.argv) > 2 else None
    data, report = {}, {}
    for run, filt in RUNS.items():
        for arm in ARMS:
            path = f"{arms_dir}/{arm}-{run}-samples.jsonl"
            if os.path.exists(path):
                data[(arm, run)] = load(path, filt)
        if vllm_dir and os.path.exists(f"{vllm_dir}/default-{run}-samples.jsonl"):
            data[("vllm", run)] = load(f"{vllm_dir}/default-{run}-samples.jsonl", filt)

    print("## Accuracy\n")
    print("| Run | Arm | n | Accuracy, % | No answer | Mean reply, tokens |")
    print("| --- | --- | --- | --- | --- | --- |")
    for run in RUNS:
        for arm in ["vllm"] + ARMS:
            s = data.get((arm, run))
            if s is None:
                continue
            acc = 100 * sum(v[0] for v in s.values()) / len(s)
            none = sum(v[1] for v in s.values())
            toks = [v[3] for v in s.values() if v[3] is not None]
            mean_toks = f"{sum(toks) / len(toks):.0f}" if toks else "—"
            print(f"| {run} | {arm} | {len(s)} | {acc:.2f} | {none} | {mean_toks} |")
            report.setdefault(run, {})[arm] = dict(n=len(s), accuracy=acc, no_answer=none)

    print("\n## Paired differences, points\n")
    print("| Run | Comparison | n | Difference | 95% interval | Gained / lost | McNemar p |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    pairs = [("off", "0.08"), ("off", "0.10"), ("0.08", "0.10"), ("vllm", "off")]
    for run in RUNS:
        for a, b in pairs:
            if (a, run) not in data or (b, run) not in data:
                continue
            r = paired(data[(a, run)], data[(b, run)])
            print(f"| {run} | {b} − {a} | {r['n']} | {r['diff']:+.2f} | {r['lo']:+.2f} to "
                  f"{r['hi']:+.2f} | {r['gained']} / {r['lost']} | {r['p']:.3f} |")
            report[run][f"{b} - {a}"] = r

    print("\n## Prompt identity\n")
    for run in RUNS:
        arms = [a for a in ["vllm"] + ARMS if (a, run) in data]
        base = data[(arms[0], run)]
        for arm in arms[1:]:
            s = data[(arm, run)]
            same = sum(base[k][2] == s[k][2] for k in base if k in s)
            print(f"- {run}: {arm} against {arms[0]}: {same} of {len(base)} prompt hashes equal")

    print("\n## Simulated cache, per decode forward\n")
    print("| Run | Arm | Hit rate, % | Foreground reads/token | Early reads used/token | "
          "Dropped/layer | Dropped weight/layer | Prefill reads/question |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for run in RUNS:
        for arm in ARMS:
            path = f"{arms_dir}/{arm}-{run}-cache.json"
            if not os.path.exists(path):
                continue
            c = json.load(open(path))
            n = report[run][arm]["n"]
            print(f"| {run} | {arm} | {c['hit_rate']:.1f} | {c['foreground_per_tok']:.2f} | "
                  f"{c['early_used_per_tok']:.2f} | {c['dropped_per_layer']:.3f} | "
                  f"{c['dropped_mass_per_layer']:.4f} | {c['prefill_reads'] / n:.0f} |")
            report[run][arm]["cache"] = c
    gsm8k_numeric(arms_dir, vllm_dir, report)
    json.dump(report, open(f"{arms_dir}/scores.json", "w"), indent=1)
    per_question(arms_dir)


def number(s):
    s = s.replace("$", "").replace(",", "").strip().rstrip(".")
    try:
        return float(s)
    except ValueError:
        return None


def gsm8k_numeric(arms_dir, vllm_dir, report):
    """Added after the scores were seen, not predicted: GSM8K regraded by the
    strict-match answer's numeric value, so "16.00" counts for a target of 16.
    strict-match itself compares strings."""
    paths = {a: f"{arms_dir}/{a}-gsm8k-samples.jsonl" for a in ARMS}
    if vllm_dir:
        paths["vllm"] = f"{vllm_dir}/default-gsm8k-samples.jsonl"
    grades = {}
    for arm, path in paths.items():
        if not os.path.exists(path):
            continue
        g = {}
        for line in open(path):
            r = json.loads(line)
            if r["filter"] != "strict-match":
                continue
            resp = r["filtered_resps"][0]
            resp = resp[0] if isinstance(resp, list) else resp
            v, t = number(resp), number(r["target"])
            right = float(v is not None and t is not None and abs(v - t) < 1e-9)
            decimals = resp != "[invalid]" and "." in resp
            g[(r["task"], r["doc_id"])] = (right, decimals)
        grades[arm] = g
    print("\n## GSM8K by numeric value (after the fact, not predicted)\n")
    print("| Arm | Strict-match answer equal in value, % | Answers written with a decimal point |")
    print("| --- | --- | --- |")
    for arm, g in grades.items():
        acc = 100 * sum(v[0] for v in g.values()) / len(g)
        print(f"| {arm} | {acc:.2f} | {sum(v[1] for v in g.values())} |")
    print("\n| Comparison | Difference | 95% interval | Gained / lost | McNemar p |")
    print("| --- | --- | --- | --- | --- |")
    for a, b in [("off", "0.08"), ("off", "0.10"), ("0.08", "0.10"), ("vllm", "off")]:
        if a in grades and b in grades:
            r = paired(grades[a], grades[b])
            print(f"| {b} − {a} | {r['diff']:+.2f} | {r['lo']:+.2f} to {r['hi']:+.2f} | "
                  f"{r['gained']} / {r['lost']} | {r['p']:.3f} |")
            report["gsm8k"][f"numeric {b} - {a}"] = r


def per_question(arms_dir):
    """per-question.tsv: each question's grade and simulated counters in every
    arm, small enough to keep where the samples files are not."""
    cols = ["correct", "no_answer", "new_tokens", "foreground", "dropped"]
    rows = {}
    for run, filt in RUNS.items():
        for arm in ARMS:
            path = f"{arms_dir}/{arm}-{run}-samples.jsonl"
            if not os.path.exists(path):
                continue
            for line in open(path):
                r = json.loads(line)
                if r["filter"] != filt:
                    continue
                c = r.get("cache") or {}
                resp = r["filtered_resps"][0]
                resp = resp[0] if isinstance(resp, list) else resp
                fg = c.get("req", 0) - c.get("hits", 0) - c.get("early_used", 0)
                rows.setdefault((r["task"], r["doc_id"]), {})[arm] = [
                    int(r["exact_match"]), int(resp == "[invalid]"), c.get("new_tokens", ""),
                    int(fg), int(c.get("dropped", 0))]
    with open(f"{arms_dir}/per-question.tsv", "w") as f:
        f.write("\t".join(["task", "doc_id"] + [f"{a}:{c}" for a in ARMS for c in cols]) + "\n")
        for (task, doc), arms in sorted(rows.items()):
            vals = [str(v) for a in ARMS for v in arms.get(a, [""] * len(cols))]
            f.write("\t".join([task, str(doc)] + vals) + "\n")


main()
