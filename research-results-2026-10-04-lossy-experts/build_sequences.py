#!/usr/bin/env python3
"""Write sequences.json for the quality meter (TurboFieldfareScore).

Each sequence is one prompt from scratch/cache-traces with the answer the
unchanged model generated for it on the Mac (its .stdout), so the meter
teacher-forces the model's own text. Twelve prompts across code, math,
logic, six languages, tables and a multi-turn chat; the meter caps each
continuation with --max-tokens.

    build_sequences.py > sequences.json
"""
import json
import os

TRACES = "/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/cache-traces"
NAMES = ["val-compare-table", "val-dialogue", "val-es-recipe", "val-fr-translate",
         "val-logic-grid", "val-multi-turn", "val-rust-borrow", "val-sql-debug",
         "train-math-proof", "train-ru-history", "train-ja-haiku", "train-py-lru"]

out = []
for name in NAMES:
    messages = json.load(open(os.path.join(TRACES, name + ".json")))
    text = open(os.path.join(TRACES, name + ".stdout")).read().strip()
    out.append({"name": name, "messages": messages, "continuation": text})
print(json.dumps(out, ensure_ascii=False, indent=1))
