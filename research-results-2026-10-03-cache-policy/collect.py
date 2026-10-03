"""Collect routing traces for cache-policy replay on the Mac, one model process
at a time, compacting each and deleting the raw trace as soon as it is done.

Usage: collect.py <repo> <cli> <out-dir> [guess.bin]

<repo>/scratch/gemma4.gturbo is the model. Each prompt in prompts.PROMPTS
becomes <out-dir>/<split>-<name>.npz, plus .stdout/.stderr with the footers
(traced runs: their timings are not benchmark figures). Prompts already
compacted are skipped, so the script can be rerun after an interruption.
Stops, without killing anything, if another model-owning process is running.
"""
import json, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "sim"))
import prompts

MODEL_PROCS = ("TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|"
               "TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm")
SEED0 = 20261003


def preflight():
    p = subprocess.run(["pgrep", "-fl", MODEL_PROCS], capture_output=True, text=True)
    others = [l for l in p.stdout.splitlines() if "collect.py" not in l]
    if others:
        sys.exit("another model-owning process is running, stopping:\n" + "\n".join(others))
    print(subprocess.run(["memory_pressure", "-Q"], capture_output=True, text=True)
          .stdout.strip().splitlines()[-1], flush=True)


def main():
    repo, cli, out = sys.argv[1], sys.argv[2], sys.argv[3]
    guess = sys.argv[4] if len(sys.argv) > 4 else None
    os.makedirs(out, exist_ok=True)
    raw_root = os.path.join(out, "raw")
    for i, (name, split, max_new, messages) in enumerate(prompts.PROMPTS):
        tag = "%s-%s" % (split, name)
        npz = os.path.join(out, tag + ".npz")
        if os.path.exists(npz):
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
        print("%s exit=%d %.0fs" % (tag, rc, time.time() - t0), flush=True)
        if rc != 0:
            sys.exit("run failed; see %s.stderr" % tag)
        args = [sys.executable, os.path.join(HERE, "sim", "compact.py"), raw, npz]
        subprocess.run(args + ([guess] if guess else []), check=True)
        shutil.rmtree(raw)
    print("all done", flush=True)


if __name__ == "__main__":
    main()
