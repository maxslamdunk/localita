#!/usr/bin/env python3
"""Summarize the prefill footers of the harness logs in logs/, one block per
run. Adapted from benchmark-results-2026-11-04-ios-prefill-routed-tensorops/;
a layer-at-a-time run reports progress per layer, so only the thermal states
and the peak footprint are kept from the progress lines.

Usage: python3 -I summarize.py [logs-dir]
"""
import re
import sys
from pathlib import Path

logs = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / "logs")


def fields(text):
    return {k: v for k, v in re.findall(r"([a-z0-9-]+)=([^\s\]|]+)", text)}


for log in sorted(logs.glob("decode-*.log")):
    lines = log.read_text().splitlines()
    print(f"== {log.name}")
    progress = [fields(l) for l in lines if ", prefill, " in l]
    thermal = sorted({f.get("thermal") for f in progress})
    peak = max((int(fields(l).get("peak", 0)) for l in lines), default=0)
    compressor = max((int(f.get("sys-compressor", 0)) for f in progress), default=0)
    print(f"  progress lines={len(progress)} thermal={','.join(map(str, thermal))}"
          f" peak footprint={peak / 1e9:.3f}GB max compressor={compressor}MB")
    for l in lines:
        if ", expert-io, " in l:
            print("  " + l[l.index("| prefill"):].split("|")[1].strip())
        if ", done, " in l:
            print("  " + l[l.index("[stop"):])
        if ", generated, " in l:
            m = re.search(r"sha256=([0-9a-f]{12})", l)
            print(f"  generated sha256={m.group(1) if m else '?'}")
    pt = next((l for l in lines if ", prefill-time, " in l), None)
    if not pt:
        continue
    sections = pt[pt.index("[prefill-time"):].split("|")
    wall, gpu, sto = fields(sections[0]), fields(sections[1]), fields(sections[2])
    print(f"  wall={wall['wall']} attn-block={wall['attn-block']} shared={wall['shared']}"
          f" routed={wall['routed']} (fetch={wall['fetch']} drain={wall['drain']})"
          f" route-plan={wall['route-plan']} tail={wall['tail']}")
    print(f"  gpu attn-block={gpu['attn-block']} shared={gpu['shared']} routed={gpu['routed']}"
          f" busy={gpu['busy']} | storage busy={sto['busy']} overlap-gpu={sto['overlap-gpu']}"
          f" both-idle={sto['both-idle']}")
