#!/usr/bin/env python3
"""Turn benchmark-results/ from Scripts/benchmark-early-read.sh into a
benchmark report in the repository's [Benchmark] issue format.

Writes benchmark-results/issue.md and prints a link that opens the
repository's benchmark issue form with every field filled in.

Usage: Scripts/early-read-report.py [results-dir] [owner/repo]
"""
import glob
import hashlib
import os
import re
import sys
import urllib.parse

OUT = sys.argv[1] if len(sys.argv) > 1 else "benchmark-results"
REPO = sys.argv[2] if len(sys.argv) > 2 else "maxslamdunk/turbo-fieldfare"
CASES = ["short-explanation", "medium-review", "long-synthesis"]
SETTINGS = [("off", "off"), ("router", "router"), ("fitted", "fitted"),
            ("fitted2", "fitted ×2")]
URL_LIMIT = 7000

FOOTER = re.compile(r"\[stop=(\S+) prefill=(\d+)tok new=(\d+)tok "
                    r"decode=([\d.]+)s tok/s=([\d.]+)\]")
EARLY = re.compile(r"needed/tok=([\d.]+) loaded-early/tok=([\d.]+) "
                   r"reads/tok=([\d.]+) precision=([\d.]+)")


def system_field(text, label):
    match = re.search(rf"^\s*{label}:\s*(.+)$", text, re.M)
    return match.group(1).strip() if match else "?"


def mean(values):
    return sum(values) / len(values) if values else None


with open(os.path.join(OUT, "system", "system.txt")) as f:
    system = f.read()
lines = system.splitlines()
commit = next((l for l in lines if re.fullmatch(r"[0-9a-f]{40}", l)), "?")
chip = system_field(system, "Chip")
memory = system_field(system, "Memory")
model = system_field(system, "Model Name")
macos = system_field(system, "ProductVersion")
build = system_field(system, "BuildVersion")
swift = re.search(r"Apple Swift version (\S+)", system)
swift = swift.group(1) if swift else "?"
power = "on power" if "AC Power" in system else "on battery"

runs = {}   # (case, setting) -> list of dicts
texts = {}  # case -> set of output hashes
for path in sorted(glob.glob(os.path.join(OUT, "measured", "*.stderr"))):
    name = os.path.basename(path)[:-len(".stderr")]
    case = next((c for c in CASES if name.startswith(c + "-")), None)
    if case is None:
        continue
    setting = name.rsplit("-", 1)[1]
    with open(path) as f:
        err = f.read()
    footer = FOOTER.search(err)
    if not footer:
        continue
    run = {"stop": footer.group(1), "prefill": int(footer.group(2)),
           "new": int(footer.group(3)), "tps": float(footer.group(5))}
    early = EARLY.search(err)
    if early:
        run.update(needed=float(early.group(1)), loaded=float(early.group(2)),
                   precision=float(early.group(4)))
    runs.setdefault((case, setting), []).append(run)
    with open(path[:-len(".stderr")] + ".stdout", "rb") as f:
        texts.setdefault(case, set()).add(hashlib.sha256(f.read()).hexdigest())

present = [(key, label) for key, label in SETTINGS
           if any((c, key) in runs for c in CASES)]


def cell(case, key, field, fmt):
    value = mean([r[field] for r in runs.get((case, key), []) if field in r])
    return fmt.format(value) if value is not None else "—"


speed = ["| case | " + " | ".join(label for _, label in present) + " |",
         "| --- |" + " ---: |" * len(present)]
for case in CASES:
    speed.append(f"| {case} | " + " | ".join(
        cell(case, key, "tps", "{:.3f}") for key, _ in present) + " |")
on = [(k, l) for k, l in present if k != "off"]
guess = ["| case | needed/tok | " + " | ".join(
    f"{l}: loaded early, precision" for _, l in on) + " |",
         "| --- | ---: |" + " ---: |" * len(on)]
for case in CASES:
    needed = cell(case, on[0][0], "needed", "{:.2f}") if on else "—"
    guess.append(f"| {case} | {needed} | " + " | ".join(
        cell(case, k, "loaded", "{:.2f}") + ", " + cell(case, k, "precision", "{:.3f}")
        for k, _ in on) + " |")
runs_per_case = {c: sum(len(runs.get((c, k), [])) for k, _ in present) for c in CASES}
results = ("Decode tok/s, mean of the runs per setting "
           f"({', '.join(f'{c} {runs_per_case[c]} runs' for c in CASES)}):\n\n"
           + "\n".join(speed)
           + "\n\nExpert reads per token with the early read on:\n\n"
           + "\n".join(guess)
           + f"\n\nOrder per case: off, router, fitted, fitted ×2, fitted ×2, fitted, "
           f"router, off; 2-minute pause before each run; one discarded warmup per case. "
           f"{model}, {power}.")
workload = "\n".join(
    "{}: prompt {} tok, generated {} tok, stop={}".format(
        c, *(lambda r: (r["prefill"], r["new"], r["stop"]))(runs[(c, present[0][0])][0]))
    for c in CASES if (c, present[0][0]) in runs)
workload += ("\nFresh process per run (cold expert cache), "
             "docs/benchmark-prompts/real-generation-v1 with their seeds.")
parity = "\n".join(
    f"{c}: {len(texts.get(c, ()))} distinct output(s) across "
    f"{runs_per_case[c]} runs"
    + (f" (SHA-256 {next(iter(texts[c]))[:16]}…)" if len(texts.get(c, ())) == 1 else "")
    for c in CASES)
command = ("Scripts/benchmark-early-read.sh (docs/COMMUNITY_BENCHMARKS.md settings: "
           "--max-new 1024 --max-context 4096 --temperature 0.2 --top-k 64 --top-p 0.95, "
           "defaults otherwise), each case run with --early-expert-read off | router | "
           "fitted, and fitted with TURBO_FIELDFARE_EARLY_EXPERT_READS=2 (\"fitted ×2\").")
fields = {
    "title": f"[Benchmark]: {chip}, {memory}, macOS {macos} — early expert read",
    "commit": commit,
    "hardware": f"{model}, {chip}, {memory}",
    "environment": f"macOS {macos} ({build}), Swift {swift}",
    "command": command,
    "workload": workload,
    "results": results,
    "parity": parity,
}

with open(os.path.join(OUT, "issue.md"), "w") as f:
    f.write(f"# {fields['title']}\n\n")
    for key, heading in [("commit", "Commit"), ("hardware", "Mac hardware and memory"),
                         ("environment", "macOS and Swift versions"),
                         ("command", "Command and runtime controls"),
                         ("workload", "Workload"), ("results", "Results"),
                         ("parity", "Correctness and output")]:
        f.write(f"## {heading}\n\n{fields[key]}\n\n")

url = (f"https://github.com/{REPO}/issues/new?"
       + urllib.parse.urlencode({"template": "benchmark.yml", **fields},
                                quote_via=urllib.parse.quote))
print("\n" + results + "\n\n" + parity + "\n")
if len(url) <= URL_LIMIT:
    print("Open this link, check the report, and press Submit:\n")
    print(url)
else:
    print(f"Open https://github.com/{REPO}/issues/new?template=benchmark.yml and "
          f"paste the sections of {OUT}/issue.md into the matching fields.")
