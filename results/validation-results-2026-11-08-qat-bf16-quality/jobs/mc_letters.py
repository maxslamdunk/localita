"""Multiple-choice scoring by the answer letter an instruct model actually gives.

lm-eval's Global-MMLU tasks score the likelihood of a bare letter as the first
token of the model's reply. Gemma 4 does not start a reply that way unprompted
(every letter came out at log-probability -12 or lower), so those scores sat
near chance. Here each question gets the instruction the model needs
("Answer with the letter only."), the chat template with thinking off, and
one greedy token. The answer is the letter with the highest log-probability
among A–D in that first position.

Usage: mc_letters.py <label> <model path> <output dir>
"""
import json
import math
import sys
import time

from lm_eval.tasks import TaskManager
from vllm import LLM, SamplingParams

label, path, out_dir = sys.argv[1:4]
TASKS = [f"global_mmlu_{lang}" for lang in ("zh", "es", "de", "fr", "ja", "ar", "hi")]
TASKS += ["global_mmlu_full_ru"]
LETTERS = "ABCD"
INSTRUCTION = "\nAnswer with the letter only."


def leaves(x):
    for k, v in x.items():
        if isinstance(v, dict):
            yield from leaves(v)
        else:
            yield k, v


items = []  # (task, subtask, doc index, prompt, gold letter)
tm = TaskManager()
for task in TASKS:
    for sub, t in leaves(tm.load([task])["tasks"]):
        name = getattr(t, "task_name", str(sub))
        for i, doc in enumerate(t.eval_docs):
            text = t.doc_to_text(doc).rstrip()
            if text.endswith("Answer:"):
                text = text[: -len("Answer:")].rstrip()
            target = t.doc_to_target(doc)
            gold = LETTERS[target] if isinstance(target, int) else str(target).strip()
            items.append((task, name, i, text + INSTRUCTION, gold))
print(f"[{label}] {len(items)} questions", flush=True)

t0 = time.time()
llm = LLM(model=path, max_model_len=4096, gpu_memory_utilization=0.90,
          limit_mm_per_prompt={"image": 0, "audio": 0}, seed=1234)
print(f"[{label}] load {time.time() - t0:.0f} s", flush=True)

tok = llm.get_tokenizer()
letter_ids = {}
for letter in LETTERS:
    ids = tok.encode(letter, add_special_tokens=False)
    assert len(ids) == 1, (letter, ids)
    letter_ids[ids[0]] = letter

params = SamplingParams(temperature=0.0, max_tokens=1, logprobs=20)
t1 = time.time()
outs = llm.chat([[{"role": "user", "content": p}] for _, _, _, p, _ in items], params,
                chat_template_kwargs={"enable_thinking": False}, use_tqdm=False)
print(f"[{label}] scored in {time.time() - t1:.0f} s", flush=True)

per_task, rows = {}, []
for (task, sub, i, _, gold), o in zip(items, outs):
    c = o.outputs[0]
    first = c.logprobs[0]
    lp = {letter: -math.inf for letter in LETTERS}
    for tid, entry in first.items():
        if tid in letter_ids:
            lp[letter_ids[tid]] = entry.logprob
    pick = max(LETTERS, key=lambda k: lp[k])
    greedy = c.text
    rows.append({"task": task, "subtask": sub, "doc": i, "gold": gold, "pick": pick,
                 "greedy": greedy, "letter_logprobs": lp})
    s = per_task.setdefault(task, [0, 0, 0])
    s[0] += pick == gold
    s[1] += 1
    s[2] += greedy.strip() in LETTERS

with open(f"{out_dir}/{label}-mc-letters-samples.jsonl", "w") as f:
    for r in rows:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
summary = {t: {"acc": c / n, "n": n, "greedy_is_letter": g / n} for t, (c, n, g) in per_task.items()}
json.dump(summary, open(f"{out_dir}/{label}-mc-letters.json", "w"), indent=1)
for t, s in summary.items():
    print(f"[{label}] {t}: acc {s['acc']:.4f} (n={s['n']}), greedy reply is a letter {s['greedy_is_letter']:.3f}",
          flush=True)
