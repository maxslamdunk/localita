"""One arm of the skip-accuracy benchmark: MMLU-Pro and GSM8K through
lm-eval's HF backend, with every reply generated under the simulated app
cache (`skipsim.py`).

Usage: eval.py <label> <model dir> <guess .bin> <out dir> <threshold> <slots> <batch size>

threshold 0 is skipping off; the cache is still simulated, for its counters.
The environment variables MMLU_LIMIT and GSM8K_LIMIT shrink the runs for a
smoke test.

Writes <out dir>/<label>-<run>.json (scores, configs, wall time),
<label>-<run>-samples.jsonl (every question, as lm-eval logs it, plus
"cache": that reply's simulated counters) and <label>-<run>-cache.json
(the counters summed over the run).
"""
import hashlib
import json
import os
import sys
import time

import torch
from lm_eval import simple_evaluate
from lm_eval.models.huggingface import HFLM

from skipsim import STAT_KEYS, CacheSim, install, load_guess

label, path, guess_path, out_dir = sys.argv[1:5]
threshold, slots, batch = float(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
RUNS = [
    # (run name, tasks, per-task limit, generation overrides), as in the QAT study
    ("mmlu_pro", ["mmlu_pro"], int(os.environ.get("MMLU_LIMIT", 143)), "temperature=0"),
    ("gsm8k", ["gsm8k_cot_llama"], int(os.environ["GSM8K_LIMIT"]) if "GSM8K_LIMIT" in os.environ
     else None, "temperature=0,max_gen_toks=1024"),
]


def key(ids):
    return hashlib.sha256(json.dumps(ids).encode()).hexdigest()


class SimLM(HFLM):
    """HFLM whose generate runs under a fresh CacheSim per batch: one row per
    question, each from an empty cache."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.state = install(self.model)
        self.guess = load_guess(guess_path).to(self.device)
        self.records = {}
        self.generated_tokens = 0

    def _model_generate(self, context, max_length, stop, **generation_kwargs):
        mask = generation_kwargs["attention_mask"].bool()
        B, T0 = context.shape
        sim = CacheSim(B, 30, 128, slots, threshold, self.device, guess=self.guess)
        sim.snapshots = []
        self.state.sim, self.state.token_valid = sim, mask
        try:
            out = super()._model_generate(context, max_length, stop, **generation_kwargs)
        finally:
            self.state.sim, self.state.token_valid = None, None
        gen = out[:, T0:].tolist()
        pad = self.tokenizer.pad_token_id
        snaps = torch.stack(sim.snapshots).cpu() if sim.snapshots else None  # [F, B, K]
        prefill = sim.stats["prefill_reads"].cpu()
        for i in range(B):
            n = gen[i].index(pad) if pad in gen[i] else len(gen[i])
            self.generated_tokens += n
            row = {k: 0.0 for k in STAT_KEYS}
            if n >= 2 and snaps is not None:
                row = dict(zip(STAT_KEYS, snaps[n - 2, i].tolist()))
            row["prefill_reads"] = prefill[i].item()
            row["new_tokens"] = n
            row["prompt_tokens"] = int(mask[i].sum())
            self.records[key(context[i][mask[i]].tolist())] = row
        return out


t0 = time.time()
lm = SimLM(pretrained=path, dtype="bfloat16", batch_size=batch, max_length=16384,
           enable_thinking=False, experts_implementation="grouped_mm")
print(f"[{label}] load {time.time() - t0:.0f} s; threshold {threshold}, {slots} slots, "
      f"batch {batch}; {type(lm.model).__name__}", flush=True)

for run, tasks, limit, gen_kwargs in RUNS:
    t1 = time.time()
    tokens0 = lm.generated_tokens
    r = simple_evaluate(model=lm, tasks=tasks, limit=limit, apply_chat_template=True,
                        fewshot_as_multiturn=True, gen_kwargs=gen_kwargs,
                        log_samples=True, random_seed=1234, numpy_random_seed=1234,
                        torch_random_seed=1234, fewshot_random_seed=1234)
    seconds = time.time() - t1
    samples = r.pop("samples", {})
    r["wall_seconds"] = seconds
    r["sim"] = {"threshold": threshold, "slots": slots, "batch": batch}
    json.dump(r, open(f"{out_dir}/{label}-{run}.json", "w"), indent=1, default=str)
    totals = {k: 0.0 for k in STAT_KEYS + ("new_tokens", "prompt_tokens")}
    missing = 0
    with open(f"{out_dir}/{label}-{run}-samples.jsonl", "w") as f:
        for task, rows in samples.items():
            for row in rows:
                ctx = row["arguments"][0][0]
                ids, m = lm.tok_batch_encode([ctx])
                rec = lm.records.get(key(ids[0][m[0].bool()].tolist()))
                if rec is None:
                    missing += 1
                elif row.get("filter") == rows[0].get("filter"):
                    for k in totals:
                        totals[k] += rec[k]
                f.write(json.dumps({"task": task, **row, "cache": rec}, default=str,
                                   ensure_ascii=False) + "\n")
    fwd = max(totals["layer_steps"] / 30, 1)
    summary = dict(totals, missing_records=missing,
                   hit_rate=100 * totals["hits"] / max(totals["req"], 1),
                   foreground_per_tok=(totals["req"] - totals["hits"] - totals["early_used"]) / fwd,
                   early_used_per_tok=totals["early_used"] / fwd,
                   dropped_per_layer=totals["dropped"] / max(totals["layer_steps"], 1),
                   dropped_mass_per_layer=totals["dropped_mass"] / max(totals["layer_steps"], 1),
                   generated_tokens=lm.generated_tokens - tokens0,
                   tokens_per_second=(lm.generated_tokens - tokens0) / seconds)
    json.dump(summary, open(f"{out_dir}/{label}-{run}-cache.json", "w"), indent=1)
    for task, metrics in sorted(r["results"].items()):
        shown = {k: round(v, 4) for k, v in metrics.items()
                 if isinstance(v, float) and "stderr" not in k}
        print(f"[{label}] {run} {task}: {shown}", flush=True)
    print(f"[{label}] {run} took {seconds:.0f} s, {summary['generated_tokens']} tokens "
          f"({summary['tokens_per_second']:.1f}/s); hit {summary['hit_rate']:.1f}%, foreground "
          f"{summary['foreground_per_tok']:.2f}/tok, dropped/layer "
          f"{summary['dropped_per_layer']:.3f}; records missing {missing}", flush=True)
