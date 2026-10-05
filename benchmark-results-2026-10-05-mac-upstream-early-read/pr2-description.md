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
| tok/s router → fitted | 4.354 → 4.498 (+3.3%) | 3.906 → 4.043 (+3.5%) | 3.463 → 3.587 (+3.6%) |
| tok/s off → fitted | **+24.7%** | **+23.0%** | **+19.1%** |
| precision router → fitted | 0.685 → 0.831 | 0.704 → 0.843 | 0.723 → 0.870 |
| output identical, 6 runs | yes | yes | yes |

Precision outside the training set, router → fitted (identical output in both):

| Russian | Chinese | Spanish | story | multi-turn chat | SQL |
| --- | --- | --- | --- | --- | --- |
| 0.492 → 0.606 | 0.507 → 0.641 | 0.568 → 0.696 | 0.683 → 0.813 | 0.690 → 0.835 | 0.704 → 0.839 |

## Remaining limitations

- Fitted for one model; another model needs its own fit, and falls back to
  the router until then.
- Fitted on English prompts only; the gain held on the Russian, Chinese and
  Spanish prompts above, but other languages and long contexts are untested.

- [x] The change does not load a complete checkpoint, shard, or large model
      tensor into Swift heap memory.
- [x] Logs and artifacts contain no credentials, private paths, or model
      weights.
