"""Print the lm-eval task names and vLLM options the benchmark needs, and fetch their datasets."""
import inspect
import re

from lm_eval.models import vllm_causallms
from lm_eval.tasks import TaskManager, get_task_dict

src = inspect.getsource(vllm_causallms.VLLM)
print("VLLM.__init__", inspect.signature(vllm_causallms.VLLM.__init__))
for key in ("enable_thinking", "chat_template_args", "chat_template_kwargs", "think_end_token"):
    print(f"  mentions {key}:", key in src)

tm = TaskManager()
names = tm.all_tasks
for pattern in (r"^mmlu_pro$", r"^mmlu_pro_", r"^gsm8k", r"^global_mmlu_[a-z]{2}$",
                r"^global_mmlu_full_[a-z]{2}$", r"mmmlu", r"^mgsm_(direct|native_cot)_[a-z]{2}$"):
    hits = [n for n in names if re.search(pattern, n)]
    print(f"{pattern}: {len(hits)}", hits[:40])

wanted = ["mmlu_pro", "gsm8k_cot_llama", "gsm8k"]
wanted += [f"global_mmlu_{lang}" for lang in ("ru", "zh", "es", "de", "fr", "ja", "ar", "hi")]
for name in wanted:
    try:
        d = get_task_dict([name], tm)
        def leaves(x):
            for k, v in x.items():
                if isinstance(v, dict):
                    yield from leaves(v)
                else:
                    yield k, v
        sizes = {}
        for k, t in leaves(d):
            docs = t.eval_docs
            sizes[getattr(t, "task_name", str(k))] = len(docs)
            cfg = t.config
        print(f"OK {name}: {sum(sizes.values())} docs in {len(sizes)} subtasks;",
              f"output_type={cfg.output_type} num_fewshot={cfg.num_fewshot}",
              f"gen_kwargs={getattr(cfg, 'generation_kwargs', None)}")
    except Exception as e:  # report and go on: the job is for finding out what exists
        print(f"FAIL {name}: {type(e).__name__}: {e}")
