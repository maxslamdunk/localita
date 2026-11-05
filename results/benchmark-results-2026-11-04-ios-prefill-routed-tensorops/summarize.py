#!/usr/bin/env python3
"""Summarize the prefill-time footers of the harness logs in logs/.

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
    starts = [l for l in lines if ", runner-ready, " in l]
    progress = [l for l in lines if ", prefill, " in l]
    t0 = int(starts[0].split(", ")[1]) if starts else None
    last = t0
    for l in progress:
        ms = int(l.split(", ")[1])
        f = fields(l)
        print(f"  chunk done={f.get('done')}/{f.get('total')} +{(ms - last) / 1000:.2f}s"
              f" thermal={f.get('thermal')} compressor={f.get('sys-compressor')}MB"
              f" footprint={int(f.get('footprint', 0)) / 1e9:.2f}GB")
        last = ms
    for name in ("expert-io", "read-latency", "prefill-time"):
        for l in lines:
            if f", {name}, " in l:
                body = l[l.index("[" + name):]
                if name == "expert-io":
                    body = body[body.index("| prefill"):]
                elif name == "read-latency":
                    body = body[body.index("| prefill"):]
                print(f"  {name}: {body}")
    for l in lines:
        if ", generated, " in l:
            m = re.search(r"sha256=([0-9a-f]{12})", l)
            print(f"  generated sha256={m.group(1) if m else '?'}")
    pt = next((l for l in lines if ", prefill-time, " in l), None)
    if not pt:
        continue
    sections = pt[pt.index("[prefill-time"):].split("|")
    wall = fields(sections[0])
    gpu = fields(sections[1])
    sto = fields(sections[2])
    w = float(wall["wall"])
    cpu = ["attn-block", "route-plan", "shared", "routed", "tail", "head"]
    total = sum(float(wall[k]) for k in cpu)
    print("  wall split: " + " ".join(
        f"{k}={float(wall[k]):.2f}s({float(wall[k]) / w * 100:.0f}%)" for k in cpu)
        + f" residual={w - total:.2f}s")
    r = float(wall["routed"])
    print(f"  routed: fetch={float(wall['fetch']):.2f}s drain={float(wall['drain']):.2f}s"
          f" other={r - float(wall['fetch']) - float(wall['drain']):.2f}s")
    busy = float(gpu["busy"])
    sb = float(sto["busy"])
    ov = float(sto["overlap-gpu"])
    print(f"  gpu busy={busy:.2f}s ({busy / w * 100:.0f}%) storage busy={sb:.2f}s"
          f" ({sb / w * 100:.0f}%) overlap={ov:.2f}s ({ov / sb * 100 if sb else 0:.0f}% of storage)"
          f" gpu-only={busy - ov:.2f}s storage-only={sb - ov:.2f}s both-idle={sto['both-idle']}s")
