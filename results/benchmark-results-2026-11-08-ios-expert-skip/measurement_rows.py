#!/usr/bin/env python3
"""Prints one MEASUREMENTS.md row per phone run of the expert-skip A/B, in run order,
with the smoke run first."""
import glob, os, re
from collections import Counter

here = os.path.dirname(os.path.abspath(__file__))
SHA = "5f5c281"
CASES = {"short": "short-explanation", "medium": "medium-review", "long": "long-synthesis"}
ORDER = ["A1", "B1", "B2", "A2"]

def runs():
    logs = glob.glob(os.path.join(here, "logs", "decode-*.log"))
    def key(p):
        label = re.search(r"decode-(\w+)-(\w\d)-", os.path.basename(p))
        return (list(CASES).index(label.group(1)), ORDER.index(label.group(2)))
    return glob.glob(os.path.join(here, "smoke", "decode-*.log")) + sorted(logs, key=key)

def row(log, index):
    text = open(log).read()
    name = os.path.basename(log)
    label, stamp = re.search(r"decode-(.+)-(\d{4}-\d\d-\d\dT\d{6}Z)\.log", name).groups()
    num = lambda p: re.search(p, text).group(1)
    phase = re.search(r"\[phase-time decode [^|]*", text).group(0)
    gpu = re.search(r"\[gpu-time decode [^|]*", text).group(0)
    field = lambda line, k: re.search(rf"\b{k}=([\d.]+)", line).group(1)
    skip = num(r"expertSkip=(\S+)")
    arm = f"**`--expert-skip {skip}`**" if skip != "off" else "no `--expert-skip` (off)"
    thermal = Counter(re.findall(r"thermal=(\w+)", text))
    thermal_s = ", ".join(f"{k} {v}" for k, v in sorted(thermal.items(), key=lambda kv: -kv[1])) + " samples"
    battery = num(r"battery=(\S+)")
    reads, early = float(num(r"reads/tok=([\d.]+) forwards")), float(num(r"early decode reads/tok=([\d.]+)"))
    config = (f"iPhone 17, 8 GB, iOS 26.6; `iOS/` app Release at `{SHA}`, installed over the app; {arm}, "
              "otherwise defaults (bundled fitted guess, `F_NOCACHE`, count aging); 24 slots LFU, "
              "`--max-new {}` `--max-context 4096`, prefill chunk `auto`, T 0.2 / Top-K 64 / Top-P 0.95, seed 1, "
              "`.fullSha256`; ")
    if label.startswith("smoke"):
        config = config.format(16) + f"single run started right after install, battery {battery}"
        case = "short"
        lead = ("short case, smoke check that the flag reaches the runner, not a speed figure and not part of "
                "the A/B. ")
    else:
        case = label.split("-")[0]
        config = config.format(1024) + (f"**expert-skip A/B**, A B B A per case with 300 s cooldowns, "
                                         f"run {label} ({index} of 12), log stamp {stamp}; battery {battery}")
        lead = ""
    stop, new = num(r"stop=(\w+)"), num(r"new=(\d+)tok")
    text_sha = num(r"generated, .*?sha256=([0-9a-f]+)")[:8]
    read_mean = num(r"read-latency decode reads=\d+ mean=([\d.]+)ms")
    skipline = re.search(r"policy=\S+ (dropped/layer [\d.]+, dropped mass/layer [\d.]+)", text)
    notes = (f"{lead}`real-generation-v1` `{CASES[case]}`: stop={stop}, new {new} tok, text SHA-256 "
             f"`{text_sha}…`. `runner-ready` `expertSkip={skip}`"
             + (f"; `expert-skip` {skipline.group(1)}" if skipline else "") + ". "
             f"reads/tok {reads:.2f}, early reads {early:.2f}/tok, foreground {reads - early:.2f}, "
             f"used {num(r'used/tok=([\d.]+)')}. Prefill {num(r'prefill bytes=([\d.]+)MB')} MiB. "
             f"`io` {field(phase, 'io')}, `cb1-wait` {field(phase, 'cb1-wait')}, head {field(phase, 'head')}, "
             f"wall {field(phase, 'wall')}; GPU attention+router {field(gpu, 'cb1')}, GPU head {field(gpu, 'head')}, "
             f"busy {field(gpu, 'busy')}; decode read mean {read_mean} ms. "
             "See `results/benchmark-results-2026-11-08-ios-expert-skip/`. |")
    return (f"| 2026-11-08 | {SHA} | {config} | {num(r'decode bytes/tok=([\d.]+)MB')} MB | "
            f"{num(r'hit-rate=([\d.]+)%')}% | {num(r'tok/s=([\d.]+)')} | {thermal_s} | {notes}")

for i, log in enumerate(runs()):
    print(row(log, i))
