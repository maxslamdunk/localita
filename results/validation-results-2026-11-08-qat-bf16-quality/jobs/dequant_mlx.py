"""Expand the app's default 4-bit MLX build back to a BF16 checkpoint vLLM can load.

The output carries the original checkpoint's tensor names and shapes, and its
config, tokenizer and chat template, so the three benchmarked models differ
only in weights. Every quantized MLX tensor is dequantized
(w = q * scale + bias per group, in float32, rounded once to BF16); every
unquantized MLX tensor is copied. Each tensor is checked against the original:
same shape, and a relative error that a correct dequantization gives (a few
percent) rather than a mis-packed one (around 100%).

Usage: dequant_mlx.py <mlx snapshot> <original snapshot> <output dir>
"""
import json
import os
import shutil
import sys

import torch
from safetensors import safe_open
from safetensors.torch import save_file

mlx_dir, orig_dir, out_dir = sys.argv[1:4]
SHARD_BYTES = 4 << 30

quant = json.load(open(f"{mlx_dir}/config.json"))["quantization"]
mlx_map = json.load(open(f"{mlx_dir}/model.safetensors.index.json"))["weight_map"]
orig_map = json.load(open(f"{orig_dir}/model.safetensors.index.json"))["weight_map"]
handles = {}


def tensor(directory, weight_map, name):
    path = f"{directory}/{weight_map[name]}"
    if path not in handles:
        handles[path] = safe_open(path, "pt")
    return handles[path].get_tensor(name)


used = set()


def mlx(name):
    used.add(name)
    return tensor(mlx_dir, mlx_map, name)


def dequant(prefix):
    spec = quant.get(prefix) or quant
    bits, group = spec["bits"], spec["group_size"]
    words = mlx(prefix + ".weight").view(torch.int32)
    scales = mlx(prefix + ".scales").float()
    biases = mlx(prefix + ".biases").float()
    per_word = 32 // bits
    shifts = torch.arange(per_word, dtype=torch.int32) * bits
    # Element j of a word sits at bits [j*bits, (j+1)*bits), lowest first.
    q = (words.unsqueeze(-1) >> shifts) & ((1 << bits) - 1)
    q = q.reshape(*words.shape[:-1], -1, group).float()
    w = q * scales.unsqueeze(-1) + biases.unsqueeze(-1)
    return w.reshape(*words.shape[:-1], -1).to(torch.bfloat16)


def load(name):
    """An MLX tensor by its MLX name, dequantized if it is stored quantized."""
    if name.endswith(".weight") and name[: -len(".weight")] + ".scales" in mlx_map:
        return dequant(name[: -len(".weight")])
    if name + ".scales" in mlx_map:
        return dequant(name)
    return mlx(name)


def mlx_name(orig):
    rest = orig[len("model."):]
    if rest.startswith("language_model."):
        return "language_model.model." + rest[len("language_model."):]
    return rest


def build(orig):
    m = mlx_name(orig)
    if m.endswith("experts.gate_up_proj"):
        base = m[: -len("gate_up_proj")] + "switch_glu."
        return torch.cat([load(base + "gate_proj"), load(base + "up_proj")], dim=1)
    if m.endswith("experts.down_proj"):
        return load(m[: -len("down_proj")] + "switch_glu.down_proj")
    return load(m)


def rel_err(a, b):
    a, b = a.float(), b.float()
    return ((a - b).norm() / b.norm().clamp_min(1e-30)).item()


# Which half of gate_up_proj is the gate: settle it on layer 0 before anything else.
o = tensor(orig_dir, orig_map, "model.language_model.layers.0.experts.gate_up_proj")
g = load("language_model.model.layers.0.experts.switch_glu.gate_proj")
half = o.shape[1] // 2
first, second = rel_err(g, o[:, :half]), rel_err(g, o[:, half:])
print(f"layer 0 gate vs gate_up_proj halves: first {first:.4f}, second {second:.4f}", flush=True)
assert first < 0.2 < second, "gate is not the first half of gate_up_proj"
used.clear()

os.makedirs(out_dir, exist_ok=True)
names = sorted(orig_map)
shard, shard_bytes, shards, weight_map, errors = {}, 0, [], {}, []


def flush():
    global shard, shard_bytes
    if not shard:
        return
    fname = f"model-{len(shards) + 1:05d}.safetensors"
    save_file(shard, f"{out_dir}/{fname}", metadata={"format": "pt"})
    for k in shard:
        weight_map[k] = fname
    shards.append(fname)
    print(f"wrote {fname}: {len(shard)} tensors, {shard_bytes / 2**30:.2f} GiB", flush=True)
    shard, shard_bytes = {}, 0


for n in names:
    t = build(n).contiguous()
    ref = tensor(orig_dir, orig_map, n)
    assert t.shape == ref.shape and t.dtype == torch.bfloat16, (n, t.shape, ref.shape, t.dtype)
    errors.append((rel_err(t, ref), n))
    shard[n] = t
    shard_bytes += t.numel() * 2
    if shard_bytes >= SHARD_BYTES:
        flush()
flush()

left = sorted(set(mlx_map) - used)
assert not left, f"MLX tensors not used: {left[:10]}"

total = sum(os.path.getsize(f"{out_dir}/{f}") for f in shards)
json.dump({"metadata": {"total_size": total}, "weight_map": weight_map},
          open(f"{out_dir}/model.safetensors.index.json", "w"), indent=1)
for f in os.listdir(orig_dir):
    if not f.endswith(".safetensors") and f != "model.safetensors.index.json":
        shutil.copy(os.path.realpath(f"{orig_dir}/{f}"), f"{out_dir}/{f}")

errors.sort()
exact = [n for e, n in errors if e == 0.0]
quantized = [(e, n) for e, n in errors if e > 0.0]
print(f"{len(errors)} tensors; {len(exact)} identical to the original; {len(quantized)} differ")
if quantized:
    print("relative error, smallest:", [(round(e, 4), n) for e, n in quantized[:3]])
    print("relative error, largest:", [(round(e, 4), n) for e, n in quantized[-5:]])
    median = quantized[len(quantized) // 2]
    print(f"relative error, median: {median[0]:.4f} ({median[1]})")
assert errors[-1][0] < 0.3, f"implausible error: {errors[-1]}"
json.dump([[e, n] for e, n in errors], open(f"{out_dir}/dequant-errors.json", "w"))
print("done", out_dir)
