"""Smoke test: load one Gemma 4 26B-A4B checkpoint in vLLM and answer a few prompts greedily."""
import json
import sys
import time

from vllm import LLM, SamplingParams

repo, revision, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
prompts = [
    "What is the capital of the Netherlands? Answer in one sentence.",
    "Объясни в двух предложениях, что такое фотосинтез.",
    "A train travels 180 km in 2.5 hours. What is its average speed in km/h? Show the calculation briefly.",
    "Write a Python function that returns the n-th Fibonacci number iteratively.",
    "Question: Which gas makes up most of Earth's atmosphere?\n"
    "A. Oxygen\nB. Nitrogen\nC. Carbon dioxide\nD. Argon\n"
    "Answer with the letter only.",
]

t0 = time.time()
llm = LLM(model=repo, revision=revision, max_model_len=4096,
          gpu_memory_utilization=0.90, limit_mm_per_prompt={"image": 0, "audio": 0})
load_s = time.time() - t0

params = SamplingParams(temperature=0.0, max_tokens=200, logprobs=5)
conversations = [[{"role": "user", "content": p}] for p in prompts]
t1 = time.time()
outs = llm.chat(conversations, params, chat_template_kwargs={"enable_thinking": False})
gen_s = time.time() - t1

rows = []
for p, o in zip(prompts, outs):
    c = o.outputs[0]
    first = c.logprobs[0] if c.logprobs else {}
    top = sorted(((v.logprob, v.decoded_token) for v in first.values()), reverse=True)
    rows.append({"prompt": p, "text": c.text, "tokens": len(c.token_ids),
                 "first_token_top5": top})
    print("=" * 80, "\nPROMPT:", p, "\nREPLY:", c.text, "\nFIRST-TOKEN TOP-5:", top, flush=True)

json.dump({"repo": repo, "revision": revision, "load_s": load_s, "generate_s": gen_s,
           "rows": rows}, open(out_path, "w"), ensure_ascii=False, indent=1)
print(f"load {load_s:.0f}s, generate {gen_s:.1f}s", flush=True)
