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

from skipsim import STAT_KEYS, CacheSim, compact_cache, install, load_guess, merge_caches

label, path, guess_path, out_dir = sys.argv[1:5]
threshold, slots, batch = float(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
RUNS = [
    # (run name, tasks, per-task limit, generation overrides), as in the QAT study
    ("mmlu_pro", ["mmlu_pro"], int(os.environ.get("MMLU_LIMIT", 143)), "temperature=0"),
    ("gsm8k", ["gsm8k_cot_llama"], int(os.environ["GSM8K_LIMIT"]) if "GSM8K_LIMIT" in os.environ
     else None, "temperature=0,max_gen_toks=1024"),
]
if os.environ.get("ONLY"):  # rerun one part of an arm, e.g. ONLY=gsm8k after a timeout
    RUNS = [r for r in RUNS if r[0] in os.environ["ONLY"].split(",")]


PREFILL_ROWS = int(os.environ.get("PREFILL_ROWS", 8))


def key(ids):
    return hashlib.sha256(json.dumps(ids).encode()).hexdigest()


def expected_lengths():
    """Reply lengths, in characters, from the QAT study's vLLM run of the same
    model (EXPECTED_LENGTHS: its samples files, comma-separated), by prompt."""
    out = {}
    for path in filter(None, os.environ.get("EXPECTED_LENGTHS", "").split(",")):
        for line in open(path):
            r = json.loads(line)
            out[r["arguments"][0][0]] = len(r["resps"][0][0])
    return out


class SimLM(HFLM):
    """HFLM whose generate runs under a fresh CacheSim per batch: one row per
    question, each from an empty cache."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.state = install(self.model)
        self.guess = load_guess(guess_path).to(self.device)
        self.records = {}
        self.generated_tokens = 0
        self.expected = expected_lengths()
        self.sorting = False

    def tok_encode(self, string, *args, **kwargs):
        # generate_until sorts its requests longest first by len(tok_encode(
        # context)), and batches them in that order. A batch runs until its
        # longest reply ends, so order by the expected reply length instead:
        # the same order, so the same batches, for every arm.
        if self.sorting and string in self.expected:
            return [0] * self.expected[string]
        return super().tok_encode(string, *args, **kwargs)

    def generate_until(self, requests, disable_tqdm=False):
        known = sum(r.args[0] in self.expected for r in requests)
        print(f"[{label}] {len(requests)} requests, {known} with an expected length", flush=True)
        self.sorting = True
        try:
            return super().generate_until(requests, disable_tqdm)
        finally:
            self.sorting = False

    def _model_generate(self, context, max_length, stop, **generation_kwargs):
        """Prefill in groups of PREFILL_ROWS rows (the whole batch at once does
        not fit), take each row's first token greedily, then let HF's generate
        continue from the merged cache. As on the phone, the prompt is
        prefill and every forward after it is decode."""
        mask = generation_kwargs["attention_mask"]
        B, T0 = context.shape
        pos = (mask.long().cumsum(-1) - 1).masked_fill(mask == 0, 0)
        sims, caches, firsts = [], [], []
        with torch.no_grad():
            for i in range(0, B, PREFILL_ROWS):
                rows = slice(i, i + PREFILL_ROWS)
                sim = CacheSim(context[rows].shape[0], 30, 128, slots, threshold, self.device,
                               guess=self.guess)
                self.state.sim, self.state.token_valid = sim, mask[rows].bool()
                try:
                    out = self.model(input_ids=context[rows], attention_mask=mask[rows],
                                     position_ids=pos[rows], use_cache=True, logits_to_keep=1)
                finally:
                    self.state.sim, self.state.token_valid = None, None
                firsts.append(out.logits[:, -1].argmax(-1))
                caches.append(compact_cache(out.past_key_values))
                sims.append(sim)
                del out
        sim = CacheSim.cat(sims)
        sim.snapshots = []
        self.peak_prefill = max(getattr(self, "peak_prefill", 0), torch.cuda.max_memory_allocated())
        first = torch.cat(firsts)[:, None]
        generation_kwargs["attention_mask"] = torch.cat([mask, torch.ones_like(first)], 1)
        self.state.sim = sim
        try:
            out = super()._model_generate(torch.cat([context, first], 1), max_length, stop,
                                          past_key_values=merge_caches(caches),
                                          **generation_kwargs)
        finally:
            self.state.sim = None
        pad = self.tokenizer.pad_token_id
        eos = self.model.generation_config.eos_token_id
        eos = set(eos if isinstance(eos, list) else [eos])
        for i in range(B):  # a reply that ends at its first token
            if first[i, 0].item() in eos:
                out[i, T0 + 1:] = pad
        gen = out[:, T0:].tolist()
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
            self.records[key(context[i][mask[i].bool()].tolist())] = row
        return out


def self_check(lm):
    """Skipping off, the sim's generate must give plain HF generate's tokens."""
    msgs = ["What is 17 times 23? Answer briefly.", "Name three rivers in Europe.",
            "Explain in one paragraph why the sky is blue, for a child of ten, without "
            "using the word light more than once.", "Write a haiku about rain."]
    ctx = [lm.apply_chat_template([{"role": "user", "content": m}]) for m in msgs]
    ids, mask = lm.tok_batch_encode(ctx)
    ids, mask = ids.to(lm.device), mask.to(lm.device)
    global threshold
    saved, threshold = threshold, 0.0
    a = lm._model_generate(ids, ids.shape[1] + 48, [], attention_mask=mask, do_sample=False)
    threshold = saved
    b = lm.model.generate(input_ids=ids, attention_mask=mask, max_length=ids.shape[1] + 48,
                          do_sample=False, pad_token_id=lm.tokenizer.pad_token_id)
    T0 = ids.shape[1]
    for i in range(len(msgs)):
        x, y = a[i, T0:].tolist(), b[i, T0:].tolist()
        same = next((j for j in range(min(len(x), len(y))) if x[j] != y[j]), None)
        print(f"self-check row {i}: {'identical' if same is None else f'differs at token {same}'}"
              f" ({len(x)} / {len(y)} tokens): {lm.tok_decode(x)[:80]!r}", flush=True)


t0 = time.time()
lm = SimLM(pretrained=path, dtype="bfloat16", batch_size=batch, max_length=16384,
           enable_thinking=False, experts_implementation="grouped_mm")
print(f"[{label}] load {time.time() - t0:.0f} s; threshold {threshold}, {slots} slots, "
      f"batch {batch}; {type(lm.model).__name__}", flush=True)

if os.environ.get("SELF_CHECK") == "1":
    self_check(lm)

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
          f"{summary['dropped_per_layer']:.3f}; records missing {missing}; peak GPU memory "
          f"{torch.cuda.max_memory_allocated() / 2**30:.1f} GiB", flush=True)
