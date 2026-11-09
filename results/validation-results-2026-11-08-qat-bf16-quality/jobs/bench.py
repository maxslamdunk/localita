"""Run the QAT-quality benchmark on one model, loading it once.

Usage: bench.py <label> <model path> <output dir>
Writes <output dir>/<label>-<run>.json (scores and configs) and
<label>-<run>-samples.jsonl (every question: prompt, reply, score).
"""
import json
import sys
import time

from lm_eval import simple_evaluate
from lm_eval.models.vllm_causallms import VLLM

label, path, out_dir = sys.argv[1:4]
# Global-MMLU-Lite has no Russian; Russian comes from the full set, 7 per subject.
LITE_LANGS = ("zh", "es", "de", "fr", "ja", "ar", "hi")
RUNS = [
    # (run name, tasks, per-task limit, generation overrides)
    ("mmlu_pro", ["mmlu_pro"], 143, "temperature=0"),
    ("gsm8k", ["gsm8k_cot_llama"], None, "temperature=0,max_gen_toks=1024"),
    ("global_mmlu", [f"global_mmlu_{lang}" for lang in LITE_LANGS], None, None),
    ("global_mmlu_ru", ["global_mmlu_full_ru"], 7, None),
]

t0 = time.time()
# The checkpoint's generation_config stays loaded: it carries the end-of-turn
# stop tokens. Its sampling defaults do not apply: every request is greedy.
lm = VLLM(pretrained=path, dtype="bfloat16", max_model_len=16384,
          gpu_memory_utilization=0.90, batch_size="auto", seed=1234,
          enable_thinking=False, limit_mm_per_prompt={"image": 0, "audio": 0})
print(f"[{label}] load {time.time() - t0:.0f} s", flush=True)

for run, tasks, limit, gen_kwargs in RUNS:
    t1 = time.time()
    r = simple_evaluate(model=lm, tasks=tasks, limit=limit, apply_chat_template=True,
                        fewshot_as_multiturn=True, gen_kwargs=gen_kwargs,
                        log_samples=True, random_seed=1234, numpy_random_seed=1234,
                        torch_random_seed=1234, fewshot_random_seed=1234)
    seconds = time.time() - t1
    samples = r.pop("samples", {})
    r["wall_seconds"] = seconds
    json.dump(r, open(f"{out_dir}/{label}-{run}.json", "w"), indent=1, default=str)
    with open(f"{out_dir}/{label}-{run}-samples.jsonl", "w") as f:
        for task, rows in samples.items():
            for row in rows:
                f.write(json.dumps({"task": task, **row}, default=str, ensure_ascii=False) + "\n")
    for task, metrics in sorted(r["results"].items()):
        shown = {k: round(v, 4) for k, v in metrics.items()
                 if isinstance(v, float) and "stderr" not in k}
        print(f"[{label}] {run} {task}: {shown}", flush=True)
    print(f"[{label}] {run} took {seconds:.0f} s", flush=True)
