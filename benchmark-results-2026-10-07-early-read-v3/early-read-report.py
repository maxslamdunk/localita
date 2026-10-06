#!/usr/bin/env python3
"""Turn benchmark-results/ from Scripts/benchmark-early-read.sh into a
benchmark report in the repository's [Benchmark] issue format.

Writes benchmark-results/issue.md (the whole report), results.md (its Results
field, also put on the clipboard) and issue-link.txt: a link that opens the
repository's benchmark issue form with every other field filled in.

Usage: Scripts/early-read-report.py [results-dir] [owner/repo]
"""
import glob
import hashlib
import os
import re
import statistics
import subprocess
import sys
import urllib.parse

OUT = sys.argv[1] if len(sys.argv) > 1 else "benchmark-results"
REPO = sys.argv[2] if len(sys.argv) > 2 else "maxslamdunk/turbo-fieldfare"
CASES = ["short-explanation", "medium-review", "long-synthesis"]
LINK_LIMIT = 6400
OUTLIER = 0.03

FOOTER = re.compile(r"\[stop=(\S+) prefill=(\d+)tok new=(\d+)tok "
                    r"decode=([\d.]+)s tok/s=([\d.]+)\]")
EARLY = re.compile(r"guess=(\S+) needed/tok=([\d.]+) loaded-early/tok=([\d.]+) "
                   r"reads/tok=([\d.]+) precision=([\d.]+)")


def system_field(text, label):
    match = re.search(rf"^\s*{label}:\s*(.+)$", text, re.M)
    return match.group(1).strip() if match else "?"


def mean(values):
    return sum(values) / len(values) if values else None


def label(setting):  # "fitted2" -> "fitted ×2"
    match = re.fullmatch(r"([a-z]+)(\d+)", setting)
    return f"{match.group(1)} ×{match.group(2)}" if match else setting


def guess_of(setting):
    return re.sub(r"\d+$", "", setting)


def pct(x):
    return f"{x:+.1%}"


def row(cells):  # A table row without padding, so the link stays short.
    return "|" + "|".join(cells) + "|"


def short(case):  # "short-explanation" -> "short"
    return case.split("-")[0]


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
header = re.search(r"order: (.+); blocks: (\d+)", system)
order = header.group(1).split() if header else []
blocks = int(header.group(2)) if header else 0
pause = system_field(system, "Pause")

# A benchmark started more than once (it resumes) has one system file per start.
starts = sorted(glob.glob(os.path.join(OUT, "system", "system-*.txt")))
commits = set()
for path in starts:
    with open(path) as f:
        commits.update(l for l in f.read().splitlines() if re.fullmatch(r"[0-9a-f]{40}", l))

runs = []
for path in glob.glob(os.path.join(OUT, "measured", "*.stderr")):
    name = os.path.basename(path)[:-len(".stderr")]
    case = next((c for c in CASES if name.startswith(c + "-")), None)
    if case is None:
        continue
    n, setting = name[len(case) + 1:].split("-", 1)
    with open(path) as f:
        err = f.read()
    footer = FOOTER.search(err)
    if not footer:
        continue
    run = {"case": case, "n": int(n), "setting": setting, "stop": footer.group(1),
           "prefill": int(footer.group(2)), "new": int(footer.group(3)),
           "tps": float(footer.group(5))}
    early = EARLY.search(err)
    if early:
        run.update(guess=early.group(1), needed=float(early.group(2)),
                   loaded=float(early.group(3)), reads=float(early.group(4)),
                   precision=float(early.group(5)))
    with open(path[:-len(".stderr")] + ".stdout", "rb") as f:
        run["text"] = hashlib.sha256(f.read()).hexdigest()
    try:
        with open(path[:-len(".stderr")] + ".conditions") as f:
            run["battery"] = "'Battery Power'" in f.read()
    except OSError:
        run["battery"] = False
    runs.append(run)
runs.sort(key=lambda r: (CASES.index(r["case"]), r["n"]))
cases = [c for c in CASES if any(r["case"] == c for r in runs)]

# Settings in the order they first appear; each step compares a setting with
# the one before it (off -> router -> fitted -> fitted x2).
settings = []
for s in order or [r["setting"] for r in runs]:
    if s not in settings:
        settings.append(s)
steps = list(zip(settings, settings[1:]))


def of(case, setting):
    return [r for r in runs if r["case"] == case and r["setting"] == setting]


# Adjacent runs: a step's pair, or two runs of the same setting (noise).
pairs = {step: {c: [] for c in cases} for step in steps}
noise = []
for c in cases:
    by_n = {r["n"]: r for r in runs if r["case"] == c}
    for n in sorted(by_n):
        a, b = by_n[n], by_n.get(n + 1)
        if b is None:
            continue
        if a["setting"] == b["setting"]:
            noise.append(abs(b["tps"] / a["tps"] - 1))
            continue
        for base, new in steps:
            if {a["setting"], b["setting"]} == {base, new}:
                x, y = (a, b) if a["setting"] == base else (b, a)
                pairs[(base, new)][c].append(y["tps"] / x["tps"] - 1)

sections = []

# 1. Speed per setting.
speed = [row(["case"] + list(map(label, settings))),
         row(["---"] + ["---:"] * len(settings))]
for c in cases:
    off = mean([r["tps"] for r in of(c, "off")])
    cells = []
    for s in settings:
        value = mean([r["tps"] for r in of(c, s)])
        if value is None:
            cells.append("—")
        elif s == "off" or not off:
            cells.append(f"{value:.3f}")
        else:
            cells.append(f"{value:.3f} ({pct(value / off - 1)})")
    speed.append(row([short(c)] + cells))
per_setting = max((len(of(c, s)) for c in cases for s in settings), default=0)
sections.append(
    f"**Speed.** Decode tok/s, mean of the {per_setting} runs of each setting, and "
    "the change from off.\n\n" + "\n".join(speed))

# 2. Each step between adjacent runs.
table = [row(["step", "case", "faster in", "median", "each pair, in run order"]),
         row(["---", "---", "---", "---:", "---"])]
overall = []
for base, new in steps:
    everything = []
    for c in cases:
        changes = pairs[(base, new)][c]
        everything += changes
        if changes:
            table.append(row([
                f"{label(new)} vs {label(base)}", short(c),
                f"{sum(x > 0 for x in changes)} of {len(changes)}",
                pct(statistics.median(changes)),
                ", ".join(f"{x * 100:+.1f}" for x in changes)]))
    if everything:
        overall.append(
            f"- **{label(new)} vs {label(base)}:** faster in "
            f"{sum(x > 0 for x in everything)} of {len(everything)} pairs, "
            f"median {pct(statistics.median(everything))}.")
sections.append(
    "**Each step, between adjacent runs.** Change in tok/s, later setting over "
    "earlier, per pair of adjacent runs.\n\n" + "\n".join(overall) + "\n\n"
    + "\n".join(table))

# 3. Noise, and runs far from the others of their setting.
notes = []
if noise:
    notes.append(
        f"**Noise.** Adjacent runs of the same setting differ by a median of "
        f"{statistics.median(noise):.1%} (largest {max(noise):.1%}, "
        f"{len(noise)} pairs).")
outliers = []
for c in cases:
    for s in settings:
        group = of(c, s)
        if len(group) < 3:
            continue
        middle = statistics.median(r["tps"] for r in group)
        for r in group:
            if abs(r["tps"] / middle - 1) > OUTLIER:
                outliers.append(f"{c} run {r['n']} ({label(s)}): {r['tps']:.3f} tok/s, "
                                f"{pct(r['tps'] / middle - 1)} from its setting's median")
if outliers:
    notes.append(f"**Runs more than {OUTLIER:.0%} from the median of their setting "
                 f"and case:** " + "; ".join(outliers) + ".")
else:
    notes.append(f"Every run is within {OUTLIER:.0%} of the median of its setting and case.")
sections.append("\n\n".join(notes))

# 4. Counters, which are exact.
on = [s for s in settings if s != "off"]
counters = [row(["case", "needed/tok"]
                + [f"{label(s)}: loaded early, precision" for s in on]),
            row(["---", "---:"] + ["---:"] * len(on))]
for c in cases:
    needed = mean([r["needed"] for s in on for r in of(c, s) if "needed" in r])
    cells = []
    for s in on:
        group = [r for r in of(c, s) if "loaded" in r]
        cells.append(f"{mean([r['loaded'] for r in group]):.2f}, "
                     f"{mean([r['precision'] for r in group]):.3f}" if group else "—")
    counters.append(row([short(c), f"{needed:.2f}" if needed is not None else "—"]
                        + cells))
sections.append("**Expert reads per token** with the early read on:\n\n"
                + "\n".join(counters))

expected = len(order) * blocks * len(CASES)
results = ("\n\n".join(sections)
           + f"\n\nOrder per case, {blocks} times: {', '.join(map(label, order))}. "
           f"{len(runs)} of {expected} runs finished. "
           f"{pause}-second pause before each run; one discarded warmup per case "
           f"(fitted ×2). {model}.")

warnings = []
fallbacks = [r for r in runs if "guess" in r and r["guess"] != guess_of(r["setting"])]
if fallbacks:
    warnings.append(f"{len(fallbacks)} fitted run(s) used the router guess (guess=router "
                    "in the footer): the model does not match the bundled guess file.")
battery = [r for r in runs if r["battery"]]
if battery:
    warnings.append(f"{len(battery)} run(s) started on battery power.")
if len(commits) > 1:
    warnings.append("The benchmark was resumed on a different commit: "
                    + ", ".join(sorted(c[:7] for c in commits)) + ".")
if len(runs) < expected:
    warnings.append(f"Only {len(runs)} of {expected} runs finished; run the script "
                    "again to finish the rest.")
for w in warnings:
    results += f"\n\n**Warning:** {w}"

first = {}
for r in runs:
    first.setdefault(r["case"], r)
workload = "\n".join(
    f"{c}: prompt {first[c]['prefill']} tok, generated {first[c]['new']} tok, "
    f"stop={first[c]['stop']}" for c in cases)
workload += ("\nFresh process per run (cold expert cache), "
             "docs/benchmark-prompts/real-generation-v1 with their seeds.")
parity = []
for c in cases:
    texts = {r["text"] for r in runs if r["case"] == c}
    count = sum(r["case"] == c for r in runs)
    parity.append(f"{c}: {len(texts)} distinct output(s) across {count} runs"
                  + (f" (SHA-256 {next(iter(texts))[:16]}…)" if len(texts) == 1 else ""))
parity = "\n".join(parity)
command = ("Scripts/benchmark-early-read.sh (docs/COMMUNITY_BENCHMARKS.md settings: "
           "--max-new 1024 --max-context 4096 --temperature 0.2 --top-k 64 --top-p 0.95, "
           "defaults otherwise), with --early-expert-read off | router | fitted; "
           "\"×2\" sets TURBO_FIELDFARE_EARLY_EXPERT_READS=2.")
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

def link(values):
    return (f"https://github.com/{REPO}/issues/new?"
            + urllib.parse.urlencode({"template": "benchmark.yml", **values},
                                     quote_via=urllib.parse.quote))


def fits(url):
    # GitHub sends a signed-out visitor to sign in with the link in return_to,
    # and drops the link when that redirect is longer than about 6,600 characters.
    return len("https://github.com/login?return_to="
               + urllib.parse.quote(url, safe="")) <= LINK_LIMIT


link_file = os.path.join(OUT, "issue-link.txt")
results_file = os.path.join(OUT, "results.md")
with open(results_file, "w") as f:
    f.write(results + "\n")
print("\n" + results + "\n\n" + parity + "\n")
# Results is too long for a link a signed-out visitor keeps through sign-in,
# so it goes on the clipboard and the link fills in everything else.
url = link({k: v for k, v in fields.items() if k != "results"})
if fits(url):
    with open(link_file, "w") as f:
        f.write(url + "\n")
    try:
        subprocess.run(["pbcopy"], input=results.encode(), check=True)
        copied = "Results is on the clipboard"
    except (OSError, subprocess.CalledProcessError):
        copied = "Copy Results with:  pbcopy < " + results_file
    print("The issue form should now open in your browser with every field filled in\n"
          f"except Results. {copied}: click into the Results field and\n"
          "press Cmd-V. Then check the report and press Submit.\n\n"
          f"To copy Results again:  pbcopy < {results_file}\n"
          f"To open the form again:  open \"$(cat {link_file})\"")
else:
    if os.path.exists(link_file):
        os.remove(link_file)
    print(f"Open https://github.com/{REPO}/issues/new?template=benchmark.yml and "
          f"paste the sections of {OUT}/issue.md into the matching fields.")
