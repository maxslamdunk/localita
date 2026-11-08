"""Collect routing traces for refitting the next-layer guess, on the Mac, one
model process at a time.

Usage: collect.py <repo> <cli> <out-dir>

The prompts are the cache-policy study's 26 (18 train, 8 val; code, math, six
languages, creative, structured, long-input, multi-turn), with its seeds and
sampling. Each becomes <out-dir>/<split>-<name>.npy: a structured array
[tokens, layers] of the top-8 experts, the router's scores over all experts,
and the router input (FP16), which is what the fit and the replay read. The raw
trace is deleted once compacted, so the peak extra disk is one raw trace. The
router weights are copied once to <out-dir>/routers/. Prompts already compacted
are skipped, so the script can be rerun after an interruption. Stops, without
killing anything, if another model-owning process is running. Traced runs:
their footers are not benchmark figures.
"""
import json, os, shutil, subprocess, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "research-results-2026-10-03-cache-policy"))
import prompts

MODEL_PROCS = ("TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|"
               "TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm")
SEED0 = 20261003  # the cache-policy study's, so its prompts get the same seeds
MIN_FREE_GIB = 1.5  # the host shares the volume with swap; a raw trace is <= ~0.35 GB


def preflight():
    p = subprocess.run(["pgrep", "-fl", MODEL_PROCS], capture_output=True, text=True)
    others = [l for l in p.stdout.splitlines() if "collect.py" not in l]
    if others:
        sys.exit("another model-owning process is running, stopping:\n" + "\n".join(others))
    print(subprocess.run(["memory_pressure", "-Q"], capture_output=True, text=True)
          .stdout.strip().splitlines()[-1], flush=True)
    free = shutil.disk_usage("/").free / 2**30
    if free < MIN_FREE_GIB:
        sys.exit("only %.1f GiB free on /, stopping" % free)


def compact(raw, out_npy, routers):
    meta = json.load(open(os.path.join(raw, "meta.json")))
    D, E, K, L = meta["hiddenSize"], meta["numExperts"], meta["topK"], meta["numLayers"]
    rec = np.dtype([
        ("position", "<i4"), ("layer", "<i4"), ("miss_count", "<i4"),
        ("experts", "<i4", K), ("misses", "<i4", K),
        ("scores", "<f4", E),
        ("router_input", "<f2", D), ("layer_output", "<f2", D),
    ])
    assert rec.itemsize == meta["recordBytes"], (rec.itemsize, meta)
    data = np.memmap(os.path.join(raw, "trace.bin"), dtype=rec, mode="r")
    T = data.shape[0] // L
    data = data[: T * L].reshape(T, L)
    assert (data["layer"] == np.arange(L)).all(), "records out of layer order"
    keep = np.dtype([("experts", "<i4", K), ("scores", "<f4", E), ("router_input", "<f2", D)])
    out = np.empty((T, L), dtype=keep)
    for f in ("experts", "scores", "router_input"):
        out[f] = data[f]
    np.save(out_npy + ".tmp.npy", out)
    os.replace(out_npy + ".tmp.npy", out_npy)
    if not os.path.isdir(routers):
        os.makedirs(routers + ".tmp", exist_ok=True)
        json.dump(meta, open(os.path.join(routers + ".tmp", "meta.json"), "w"))
        for i in range(L):
            name = "router_L%02d.f32" % i
            shutil.copy(os.path.join(raw, name), os.path.join(routers + ".tmp", name))
        os.replace(routers + ".tmp", routers)
    return T


def main():
    repo, cli, out = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    raw_root = os.path.join(out, "raw")
    for i, (name, split, max_new, messages) in enumerate(prompts.PROMPTS):
        tag = "%s-%s" % (split, name)
        npy = os.path.join(out, tag + ".npy")
        if os.path.exists(npy):
            continue
        preflight()
        raw = os.path.join(raw_root, tag)
        shutil.rmtree(raw, ignore_errors=True)
        msgs = os.path.join(out, tag + ".json")
        json.dump(messages, open(msgs, "w"), ensure_ascii=False, indent=1)
        env = dict(os.environ, TURBO_FIELDFARE_ROUTING_TRACE=raw)
        t0 = time.time()
        with open(os.path.join(out, tag + ".stdout"), "w") as so, \
                open(os.path.join(out, tag + ".stderr"), "w") as se:
            rc = subprocess.run(
                [cli, "--model", os.path.join(repo, "scratch", "gemma4.gturbo"),
                 "--messages-file", msgs, "--max-new", str(max_new), "--max-context", "4096",
                 "--temperature", "0.2", "--top-k", "64", "--top-p", "0.95",
                 "--seed", str(SEED0 + i)], stdout=so, stderr=se, env=env).returncode
        if rc != 0:
            sys.exit("%s failed (exit %d); see %s.stderr" % (tag, rc, tag))
        T = compact(raw, npy, os.path.join(out, "routers"))
        shutil.rmtree(raw)
        print("%s %d tokens %.0fs" % (tag, T, time.time() - t0), flush=True)
    print("all done", flush=True)


if __name__ == "__main__":
    main()
