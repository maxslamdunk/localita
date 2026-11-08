#!/usr/bin/env python3
"""Grades the expert-skip accuracy check: each arm's 50 replies against the
GSM-Symbolic P2 answers, paired by problem.

usage: grade.py P2_TEST_JSONL
"""
import glob, math, os, re, sys
from make_prompts import selected, case_id

here = os.path.dirname(os.path.abspath(__file__))
FINAL = re.compile(r"Final answer:?\**\s*[:=]?\s*\**\s*\\?\$?\s*\\?\(?\s*(?:\\boxed\{)?\s*(-?[\d,]*\.?\d+)", re.I)
NUMBER = re.compile(r"-?\d[\d,]*\.?\d*")

def value(s):
    return float(s.replace(",", "").rstrip("."))

def answer(text):
    """The reply's final answer and whether it used the asked-for line."""
    marked = FINAL.findall(text)
    if marked:
        return value(marked[-1]), True
    numbers = NUMBER.findall(text)
    return (value(numbers[-1]), False) if numbers else (None, False)

def same(a, b):
    return a is not None and math.isclose(a, b, rel_tol=1e-4, abs_tol=1e-6)

def arm(label):
    logs = sorted(glob.glob(os.path.join(here, "logs", f"decode-{label}-*Z.log")))
    if not logs:
        return None
    log = logs[-1]
    text = open(log).read()
    runs = {}
    for line in text.splitlines():
        m = re.search(r", done, .*\[stop=(\w+) prefill=(\d+)tok new=(\d+)tok decode=([\d.]+)s tok/s=([\d.]+)\].* case=(gsmp2-\d\d)", line)
        if m:
            runs[m.group(6)] = dict(stop=m.group(1), new=int(m.group(3)), secs=float(m.group(4)))
    for case in runs:
        runs[case]["text"] = open(log[:-4] + f"-{case}.txt").read()
    skip = re.search(r"expertSkip=(\S+)", text)
    return dict(log=os.path.basename(log), skip=skip.group(1) if skip else "absent", runs=runs)

def binom_two_sided(k, n):
    """Exact McNemar: two-sided binomial p for k of n discordant pairs."""
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(0, min(k, n - k) + 1)) / 2 ** n
    return min(1.0, 2 * tail)

def first_difference(a, b):
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))

problems = selected(sys.argv[1])
gold = {case_id(r): value(r["answer"].strip().splitlines()[-1].lstrip("#").strip()) for r in problems}
arms = {k: arm(k) for k in ("acc-A", "acc-B")}
right = {}
for label, a in arms.items():
    if a is None:
        print(f"{label}: no log"); continue
    runs = a["runs"]
    right[label] = {}
    unmarked = []
    for case in gold:
        if case not in runs:
            continue
        got, marked = answer(runs[case]["text"])
        right[label][case] = same(got, gold[case])
        if not marked:
            unmarked.append(case)
    n = len(right[label])
    new = sum(r["new"] for r in runs.values()); secs = sum(r["secs"] for r in runs.values())
    stops = {}
    for r in runs.values():
        stops[r["stop"]] = stops.get(r["stop"], 0) + 1
    print(f"{label} ({a['log']}, expertSkip={a['skip']}): {sum(right[label].values())} of {n} right; "
          f"stops {stops}; no `Final answer` line: {unmarked or 'none'}; "
          f"new tokens mean {new / max(1, len(runs)):.0f}; decode {new / max(secs, 1e-9):.3f} tok/s over {secs / 60:.1f} min")

if len(right) == 2:
    A, B = right["acc-A"], right["acc-B"]
    common = sorted(set(A) & set(B))
    only_a = [c for c in common if A[c] and not B[c]]
    only_b = [c for c in common if B[c] and not A[c]]
    ta = {c: arms["acc-A"]["runs"][c]["text"] for c in common}
    tb = {c: arms["acc-B"]["runs"][c]["text"] for c in common}
    identical = [c for c in common if ta[c] == tb[c]]
    firsts = sorted(first_difference(ta[c], tb[c]) for c in common if ta[c] != tb[c])
    print(f"paired over {len(common)}: both right {sum(A[c] and B[c] for c in common)}, "
          f"both wrong {sum(not A[c] and not B[c] for c in common)}, "
          f"A only {len(only_a)} {only_a}, B only {len(only_b)} {only_b}; "
          f"exact McNemar p = {binom_two_sided(len(only_b), len(only_a) + len(only_b)):.3f}")
    print(f"texts identical: {len(identical)}; first differing character, median "
          f"{firsts[len(firsts) // 2] if firsts else '-'} (quartiles "
          f"{firsts[len(firsts) // 4] if firsts else '-'}–{firsts[3 * len(firsts) // 4] if firsts else '-'})")
    for c in common:
        ga, gb = answer(ta[c])[0], answer(tb[c])[0]
        flag = "" if A[c] == B[c] else "  <-- differs"
        print(f"  {c}: gold {gold[c]:g}  A {ga}  {'ok' if A[c] else 'WRONG'}  B {gb}  {'ok' if B[c] else 'WRONG'}{flag}")
