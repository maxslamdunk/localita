"""Checks the simulation against the phone: teacher-force the iPhone 17's own
replies from the 2026-11-08 skip A/B through the HF model with the simulated
cache, and compare the cache counters with the phone's footers.

Usage: teacher.py <model dir> <guess .bin> <phone logs dir> <prompts dir> <out .json>

One run per case and arm: A (skipping off) and B (`miss:0.08`). A1 and A2
generated the same text, as did B1 and B2, so the first of each is used. The
prompt goes through prefill; then each of the phone's tokens is fed in turn,
as the phone's decode forwards fed them. The phone sampled at T 0.2, so the
replies are teacher-forced, not regenerated.
"""
import glob
import json
import os
import re
import sys
import time

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from skipsim import CacheSim, install, load_guess

model_dir, guess_path, logs_dir, prompts_dir, out_path = sys.argv[1:6]
SLOTS = 24
END_OF_TURN = 106

tok = AutoTokenizer.from_pretrained(model_dir)
t0 = time.time()
model = AutoModelForCausalLM.from_pretrained(model_dir, dtype=torch.bfloat16, device_map="cuda",
                                             experts_implementation="grouped_mm")
model.eval()
print(f"load {time.time() - t0:.0f} s, {type(model).__name__}", flush=True)
state = install(model)
guess = load_guess(guess_path).cuda()


def footer(log):
    text = open(log).read()
    def grab(pattern, cast=float):
        m = re.search(pattern, text)
        return cast(m.group(1)) if m else None
    return {
        "case": grab(r"case=(\S+)", str),
        "prompt_tokens": grab(r"prompt-encoded.*tokens=(\d+)", int),
        "skip": grab(r"expertSkip=(\S+)", str) or "off",
        "new": grab(r"new=(\d+)tok", int),
        "stop": grab(r"\[stop=(\w+)", str),
        "forwards": grab(r"forwards=(\d+)", int),
        "hit_rate": grab(r"decode bytes/tok=[\d.]+MB hit-rate=([\d.]+)%"),
        "reads_per_tok": grab(r"reads/tok=([\d.]+) forwards"),
        "early_used_per_tok": grab(r"used/tok=([\d.]+)"),
        "prefill_reads": grab(r"prefill bytes=[\d.]+MB hit-rate=[\d.]+% reads=(\d+)", int),
        "dropped_per_layer": grab(r"dropped/layer ([\d.]+)"),
        "dropped_mass_per_layer": grab(r"dropped mass/layer ([\d.]+)"),
    }


@torch.no_grad()
def run(prompt_ids, reply_ids, threshold):
    sim = CacheSim(1, 30, 128, SLOTS, threshold, "cuda", guess=guess)
    state.sim, state.token_valid = sim, None
    try:
        out = model(input_ids=torch.tensor([prompt_ids], device="cuda"), use_cache=True,
                    logits_to_keep=1)
        cache = out.past_key_values
        agree = int(out.logits[0, -1].argmax().item() == reply_ids[0])
        for i, t in enumerate(reply_ids[:-1]):
            out = model(input_ids=torch.tensor([[t]], device="cuda"), past_key_values=cache,
                        use_cache=True)
            cache = out.past_key_values
            agree += int(out.logits[0, -1].argmax().item() == reply_ids[i + 1])
    finally:
        state.sim = None
    s = {k: v[0] for k, v in sim.row_stats().items()}
    fwd = len(reply_ids) - 1
    misses = s["req"] - s["hits"]
    return {
        "forwards": fwd,
        "hit_rate": 100 * s["hits"] / s["req"],
        "reads_per_tok": (misses + s["early_issued"] - s["early_used"]) / fwd,
        "early_used_per_tok": s["early_used"] / fwd,
        "foreground_per_tok": (misses - s["early_used"]) / fwd,
        "prefill_reads": s["prefill_reads"],
        "dropped_per_layer": s["dropped"] / s["layer_steps"],
        "dropped_mass_per_layer": s["dropped_mass"] / s["layer_steps"],
        "top1_agrees_with_phone": agree / len(reply_ids),
    }


results = []
for log in sorted(glob.glob(os.path.join(logs_dir, "decode-*-[AB]1-*.log"))):
    phone = footer(log)
    phone["foreground_per_tok"] = (240 * (1 - phone["hit_rate"] / 100)
                                   - phone["early_used_per_tok"])
    messages = json.load(open(os.path.join(prompts_dir, phone["case"] + ".json")))
    prompt_ids = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=True,
                                         enable_thinking=False, return_dict=False)
    reply = open(log[:-4] + ".txt").read()
    reply_ids = tok(reply, add_special_tokens=False).input_ids
    if phone["stop"] == "endOfTurn":
        reply_ids = reply_ids + [END_OF_TURN]
    threshold = float(phone["skip"].split(":")[1]) if phone["skip"] != "off" else 0.0
    t1 = time.time()
    sim = run(prompt_ids, reply_ids, threshold)
    row = {"log": os.path.basename(log), "skip": phone["skip"],
           "prompt_tokens": len(prompt_ids), "reply_tokens": len(reply_ids),
           "seconds": round(time.time() - t1, 1), "phone": phone, "sim": sim}
    results.append(row)
    print(json.dumps(row), flush=True)

json.dump(results, open(out_path, "w"), indent=1)
print(f"{'case':>18s} {'arm':>9s} | {'':>4s} {'hit %':>6s} {'reads':>6s} {'used':>6s} {'fg':>6s} "
      f"{'drop/L':>7s} {'mass/L':>7s} {'pf rd':>6s} {'tok':>5s}")
for r in results:
    for who in ("phone", "sim"):
        d = r[who]
        n = d["forwards"] + 1 if who == "sim" else d["new"]
        print(f"{r['phone']['case']:>18s} {r['skip']:>9s} | {who:>5s} {d['hit_rate']:6.1f} "
              f"{d['reads_per_tok']:6.2f} {d['early_used_per_tok']:6.2f} {d['foreground_per_tok']:6.2f} "
              f"{(d['dropped_per_layer'] or 0):7.3f} {(d['dropped_mass_per_layer'] or 0):7.4f} "
              f"{int(d['prefill_reads']):6d} {n:5d}")
    print(f"{'':>18s} {'':>9s} | prompt tokens {r['prompt_tokens']} (phone "
          f"{r['phone']['prompt_tokens']}), teacher-forced top-1 agreement "
          f"{100 * r['sim']['top1_agrees_with_phone']:.1f}%")
