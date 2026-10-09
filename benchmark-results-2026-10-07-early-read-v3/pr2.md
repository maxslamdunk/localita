## Summary

Builds on #PR1; please review that one first. This PR makes the early read
guess better and read more:

1. **A fitted guess.** The early read scores layer L+1's experts as
   `x_L · W_{L+1}ᵀ`: layer L's router input times layer L+1's router. The
   fitted guess adds a per-layer correction, `x_L · (W_{L+1} + B_{L+1})ᵀ`.
   Only `B` is fitted (ridge regression on routing traces); `W` is the
   model's own router, unchanged. Precision rises from 0.69–0.72 to
   0.83–0.87. This PR ships `W + B` for gemma4, pre-added and quantized to the
   router's 8-bit format so the existing router kernel runs it unchanged
   (`NextLayerGuess/`, 11.1 MB, mapped read-only). The file holds only the
   sum, so it is derived from the model's router weights but does not contain
   them (Gemma 4 is Apache 2.0). `--early-expert-read fitted` is the
   new default; a model with no fitted file falls back to `router`. The
   `[early-read …]` line names the guess that ran.
2. **Two reads per layer.** With the fitted guess, a second early read per
   layer paid off on every Mac tested. `TURBO_FIELDFARE_EARLY_EXPERT_READS=1`
   restores one.

How it was fitted: routing traces of seven prompts (2,119 decode tokens) on
an M1, scored on the three benchmark prompts, which the fit never saw. On six
more prompts outside the training set (Russian, Chinese, Spanish, a story, a
multi-turn chat, SQL), precision rose by 0.11–0.15 on every one. The trace
recorder and the fitting script (numpy, about 130 lines) can follow as a
separate PR, so the file can be refitted or fitted for another model.

## Validation

- Same checks as #PR1. New tests: the loader reproduces the CPU reference
  through the router GEMV, rejects bad headers and sizes, and finds the
  shipped file by snapshot hash with a matching SHA-256; the read-count
  default.
- Real model: the same runs on the same five Macs as #PR1.

## Memory and performance

11.1 MB of read-only mapped file, and a second 3.36 MB staging buffer.

Decode tok/s, short / medium / long. The steps are the median change over the
4 adjacent pairs of each case; the total compares the mean of 4 runs each.

| Mac | fitted vs router | two reads vs one | total, off → this PR |
| --- | --- | --- | --- |
| M1 MacBook Air, 8 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/5)) | +4.3 / +4.7 / +4.0% | +11.5 / +13.7 / +14.8% | **+37 / +42 / +40%** |
| M1 MacBook Pro, 8 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/7)) | +3.8 / +2.3 / +2.4% | +9.8 / +12.6 / +12.6% | **+29 / +31 / +29%** |
| M1 MacBook Pro, 16 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/4)) | +0.9 / +1.6 / +1.9% | +4.9 / +2.4 / +3.6% | **+37 / +36 / +33%** |
| M3 MacBook Air, 16 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/8)) | +1.3 / +1.7 / −3.3% | +12.3 / +23.8 / +65.8% | **+46 / +46 / +67%** |
| M4 MacBook Air, 16 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/9)) | +0.4 / −0.3 / +0.9% | +8.7 / +9.8 / +11.2% | **+23 / +21 / +23%** |

Two reads beat one in all 60 pairs. Generated text was identical across every
run of each case on every Mac.

## Remaining limitations

- At one read, the fitted guess gained little on the 16 GB Macs, and nothing
  on the M4 (median −0.05%, faster in 5 of 12 pairs) or in the M3's long case
  (−3.3%). With two reads, the default, every case on every Mac was faster
  than with one.
- Fitted on English prompts. The gain held on the Russian, Chinese and Spanish
  prompts above; other languages are untested.

- [x] The change does not load a complete checkpoint, shard, or large model
      tensor into Swift heap memory.
- [x] Logs and artifacts contain no credentials, private paths, or model
      weights.
