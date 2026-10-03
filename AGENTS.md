# TurboFieldfare — iOS port

Swift and Metal inference for Gemma 4 26B-A4B on Apple Silicon. This repository
is the **iOS port**, derived from [`drumih/turbo-fieldfare`](https://github.com/drumih/turbo-fieldfare)
(Apache-2.0).

**[`CLAUDE.md`](CLAUDE.md) is the contract — read it first.** It holds the
goal (fast Gemma 4 on the iPhone 17), the measured facts, the safety
invariants, the architecture, and the working agreements.
[`docs/IOS_PORT.md`](docs/IOS_PORT.md) is the active plan.

This file exists for agent tools that look for `AGENTS.md` rather than
`CLAUDE.md`. It is deliberately a pointer and not a copy: everything here would
otherwise duplicate `CLAUDE.md` and drift out of sync with it.

Two things that hold regardless of what you were asked to do:

- **Exactly one model-owning process at a time** (app, decode service, CLI,
  server, or a model-using test). This is a memory invariant of the 8 GB
  validation host, not a convention.
- **If a preflight check fails, stop and tell the user.** Never terminate a
  running process, and never delete or reinstall the model.
- **Never delete the iOS app from the phone.** The model lives in its data
  container; install new builds over it.
