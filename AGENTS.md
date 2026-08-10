# TurboFieldfare — iOS port

Swift and Metal inference for Gemma 4 26B-A4B on Apple Silicon. This repository
is the **iOS port**, derived from [`drumih/turbo-fieldfare`](https://github.com/drumih/turbo-fieldfare)
(Apache-2.0).

## Scope

Building the iPhone port and lowering bytes read per token are the work. Editing
source, changing runtime defaults, and optimization are all in scope — this is a
development checkout, not a run-and-report one.

`docs/IOS_PORT.md` is the active plan and states the current priority order.
`CLAUDE.md` holds the binding constraint, the measured facts, and the working
agreements. Read those two before proposing work.

What stays out of scope unless asked: rewriting the Mac runtime for its own
sake, and any change justified only by GPU time. The binding constraint is
bytes/token, and a change that leaves it flat needs a different justification —
correctness, the memory ceiling, or iOS portability.

## Layout and commands

`Sources/TurboFieldfareFormat/` owns the Foundation-only `.gturbo` v1 wire
contract. `Sources/TurboFieldfare/` is the runtime; `Sources/TurboFieldfareRepack/`,
`Sources/TurboFieldfareCLI/`, `Sources/TurboFieldfareServer/`, and
`Sources/TurboFieldfareApp/` contain the installer, CLI, loopback server, and
Mac app.
`Tests/` contains focused public tests; `docs/` contains design, benchmark, and
experiment notes.

```bash
swift run -c release TurboFieldfareRepack --output scratch/gemma4.gturbo
swift run -c release TurboFieldfareRepack --output scratch/gemma4.gturbo --resume
swift build -c release
.build/release/TurboFieldfareMac
swift run -c release TurboFieldfareCLI \
  --model scratch/gemma4.gturbo \
  --prompt "The capital of France is" \
  --max-new 64
```

The installer streams the pinned model without staging the full source checkpoint. Set `HF_TOKEN` only if requested. The download is about 15 GB. Cancellation preserves verified completed ranges; continue them with `--resume` or remove them with `--discard-partial --output scratch/gemma4.gturbo`.

## Safety invariants

These are physical constraints of the 8 GB validation host, not conventions, and
they hold regardless of what work is in flight.

Before a model run, require macOS 26+, Swift 6.2+, enough disk, acceptable
`memory_pressure -Q`, a completed `scratch/gemma4.gturbo`, and no process from
`pgrep -fl 'TurboFieldfareServer|TurboFieldfareMac|TurboFieldfareDecodeService|TurboFieldfareCLI|TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm'`.
**If a check fails, inform the user and stop; do not terminate apps or delete or
reinstall the model.**

Exactly one model-owning process at a time — app, decode service, CLI, server, or
a model-using test. Do not download a full checkpoint, duplicate the `.gturbo`
model, or purge caches just to run tests.

Run package tests through `Scripts/test.sh`.

For performance results, build release once and follow the
[community benchmark guide](docs/COMMUNITY_BENCHMARKS.md) exactly. Do not enable
experimental controls or profiling. Report the commit, hardware and RAM, macOS,
Swift version, exact command, exit code, complete timing footer or error, and
every protocol deviation. Append a row to `MEASUREMENTS.md`. Treat results as
measurements, not performance ceilings.

## Local server

Follow the [server guide](docs/OPENAI_SERVER.md) for launch commands, health
checks, client setup, prompt reuse, tool loops, and supported API behavior.
Apply the model-process checks above first; never start a second model process
or terminate an existing one.

Keep the server on `127.0.0.1`; it has no remote authentication or TLS, so do
not proxy, tunnel, or expose it. A tool call from the local model never bypasses
the client's normal permission policy. Keep the execution session alive while
the server is needed, and stop only a server you launched.

## App controls

The Mac app sends prompts through the pinned Gemma 4 IT chat format. It
exposes context length, temperature, Top-K, Top-P, expert-cache slots, prefill,
and RDADVISE. The defaults are temperature `0.2`, Top-K `64`, and Top-P `0.95`.
Responses can use the context space left after formatting the prompt, and FP16
is the runtime KV format. The HUD shows generation rate, token count, and
decode-service memory; Last run also shows time to first token and I/O. Build
the app with its sibling `TurboFieldfareDecodeService`; it never loads a second
in-process model. See [README](README.md) and [Runtime controls](docs/RUNTIME_CONTROLS.md).
