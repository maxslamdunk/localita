#!/usr/bin/env python3
"""Print MEASUREMENTS.md rows for the phone logs in logs/ and the Mac check.

Usage: python3 -I measurement_rows.py
"""
import re
from pathlib import Path

here = Path(__file__).parent
SHA = "4fd99e1"
PHONE = ("iPhone 17, 8 GB, iOS 26.6; `iOS/` app Release at `4fd99e1` (branch `prefill-port`, code `f497818`), "
         "installed over the app; defaults (bundled fitted guess, one early read, `F_NOCACHE`, "
         "count aging, routed matrix units), 24 slots LFU, **`--max-new 32`** `--max-context 4096`, "
         "prefill chunk `auto`, T 0.2 / Top-K 64 / Top-P 0.95, seed 1, {load}; "
         "**prefill resume fix, {arm}**; log stamp {stamp}; battery {battery}")
ARMS = {"A": "defaults (layer at a time, alternating row buffers)"}
CASES = {"resume": "long-synthesis"}


def fields(text):
    return dict(re.findall(r"([a-z0-9/-]+)=([^\s\]|,]+)", text))


def section(line, name):
    return line[line.index("[" + name):]


for log in sorted((here / "logs").glob("decode-*.log")):
    m = re.match(r"decode-(\w+)-([AB])(\d)-(\S+)\.log", log.name)
    kind, arm, n, stamp = m.groups()
    lines = log.read_text().splitlines()
    get = lambda tag: next(l for l in lines if f", {tag}, " in l)
    battery = fields(get("start"))["battery"]
    thermals = [fields(l).get("thermal") for l in lines if "thermal=" in l]
    states = sorted(set(thermals))
    io = section(get("expert-io"), "expert-io")
    dec = fields(io.split("|")[0])
    pre = fields(io.split("|")[1])
    done = fields(section(get("done"), "stop"))
    pt = section(get("prefill-time"), "prefill-time").split("|")
    w, g, s = fields(pt[0]), fields(pt[1]), fields(pt[2])
    sha = re.search(r"sha256=([0-9a-f]{8})", get("generated")).group(1)
    peak = max(int(fields(l).get("peak", 0)) for l in lines)
    load = "`--trust-install` (no SHA-256 of the layer files)" if kind == "trust" else \
        "`.fullSha256` (receipt path mismatch)"
    config = PHONE.format(load=load, arm=ARMS[arm], stamp=stamp, battery=battery)
    notes = (f"Run `{kind}-{arm}{n}`, `real-generation-v1` `{CASES[kind]}`: text SHA-256 `{sha}…` "
             f"({done['new']}). `[prefill-time]` wall {w['wall']} s, chunks {w['chunks']}; "
             f"attention block {w['attn-block']}, shared {w['shared']}, routed phase {w['routed']} "
             f"(fetch {w['fetch']}, drain {w['drain']}); GPU routed {g['routed']}, shared {g['shared']}, "
             f"attention block {g['attn-block']}, busy {g['busy']}; storage busy {s['busy']}, "
             f"{s['overlap-gpu']} under GPU. Prefill {pre['bytes'].rstrip('MB')} MiB, {pre['reads']} reads. "
             f"Peak footprint {peak / 1e9:.3f} GB. Decode figures are over {dec['forwards']} forwards, "
             f"not comparable with 1024-token rows. See "
             f"`results/benchmark-results-2026-11-06-ios-prefill-resume/`.")
    thermal = f"{states[0]} {len(thermals)} samples" if len(states) == 1 else ", ".join(states)
    print(f"| 2026-11-06 | {SHA} | {config} | {dec['bytes/tok']} | {dec['hit-rate']} | "
          f"{done['tok/s']} | {thermal} | {notes} |")

MAC = ("M1 MacBook Air 8 GB, macOS 26.6.1; `TurboFieldfareCLI` release at `4fd99e1` (branch "
       "`prefill-port`, code `f497818`), `scratch/gemma4.gturbo`, defaults (16 slots, chunk 128), `--messages-file`, "
       "**`--max-new 48` `--temperature 0`**; **prefill resume fix, Mac check, {arm}**")
MAC_ARMS = {"A": "defaults"}
for log in sorted((here / "mac-check").glob("*.log")):
    case, arm = log.stem.rsplit("-", 1)
    text = log.read_text()
    lines = text.splitlines()
    sec = lambda name: next(section(l, name) for l in lines if l.startswith("[" + name))
    io = sec("expert-io")
    dec, pre = fields(io.split("|")[0]), fields(io.split("|")[1])
    done = fields(sec("stop"))
    w = fields(sec("prefill-time").split("|")[0])
    import hashlib
    sha = hashlib.sha256((here / "mac-check" / f"{case}-{arm}.txt").read_bytes()).hexdigest()[:8]
    notes = (f"`real-generation-v1` `{case}`, greedy: text SHA-256 `{sha}…` ({done['new']}). "
             f"Prefill {pre['bytes'].rstrip('MB')} MiB, {pre['reads']} reads; `[prefill-time]` wall "
             f"{w['wall']} s, chunks {w['chunks']}. Correctness check, not the Mac protocol. See "
             f"`results/benchmark-results-2026-11-06-ios-prefill-resume/mac-check/`.")
    print(f"| 2026-11-06 | {SHA} | {MAC.format(arm=MAC_ARMS[arm])} | {dec['bytes/tok']} | "
          f"{dec['hit-rate']} | {done['tok/s']} | not recorded | {notes} |")
