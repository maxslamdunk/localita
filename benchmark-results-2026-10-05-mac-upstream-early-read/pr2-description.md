## Summary

Builds on #TBD. The early read guesses the next layer's experts with that
layer's router applied to the current layer's router input. A per-layer ridge
correction to that router, fitted offline, guesses right more often. This PR
ships the fitted matrices for gemma4 (`NextLayerGuess/`, 11.1 MB, mapped
read-only, in the router's own 8-bit format so the same GEMV runs it) and makes
`--early-expert-read fitted` the default. A model with no fitted file falls
back to `router`. The `[early-read …]` line names the guess that ran.

How it was fitted: routing traces of seven app prompts (2,119 decode tokens) on
an M1; ridge strength chosen on two of them; scored on the three
`real-generation-v1` prompts, which the fit never saw. The fitting scripts and
the trace recorder they need can follow in a separate PR if wanted.

## Validation

- Full checks as in #TBD; new tests: the loader reproduces the dequantized
  CPU reference through the router GEMV, rejects bad headers and sizes, and
  finds the shipped file by snapshot hash with a matching SHA-256.
- Real model: same benchmark runs as #TBD, fitted vs router.
- Outside the training set: six more prompts (Russian, Chinese, Spanish, a
  story, a multi-turn chat, SQL), router vs fitted.

## Memory and performance

11.1 MB of read-only mapped file. M1 MacBook Air 8 GB, 16 slots:

| | short | medium | long |
| --- | --- | --- | --- |
| tok/s router → fitted | TBD | TBD | TBD |
| precision router → fitted | TBD | TBD | TBD |
| output identical | TBD | TBD | TBD |

Out-of-domain precision, router → fitted: TBD.

## Remaining limitations

- Fitted for one model; another model needs its own fit, and falls back to
  the router until then.
- Fitted on English prompts only; see the out-of-domain row.

- [x] The change does not load a complete checkpoint, shard, or large model
      tensor into Swift heap memory.
- [x] Logs and artifacts contain no credentials, private paths, or model
      weights.
