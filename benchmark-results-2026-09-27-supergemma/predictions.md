# Predictions: SuperGemma 4 on `real-generation-v1` (Mac)

Written before any model run on this checkpoint. Branch `supergemma-model`, forked from
`6266f48`. Model: `scratch/supergemma4.gturbo`, installed 2026-09-27 by
`TurboFieldfareRepack --source supergemma4` from
`Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2` at
`1ecb7582718b813fc4c7b5c3131b2b7053787f00`. Host: the 8 GB M1 validation host, volume
about 75% full. Comparison: HEAD rows in `CLAUDE.md` (post-merge binary, reference
checkpoint): 260.2 / 281.9 / 309.3 MB/token, hit rate 67.7 / 65.0 / 61.6%, 3.729 /
3.255 / 2.897 tok/s.

## What is and is not different

- **Layout: identical.** Same 1,339 text tensors, same shapes, same MLX 4-bit g64 plus
  8-bit router quantization, same `expertStride` 3,358,720 B, same 14,251,255,868 B of
  payload written. So the zero-hit ceiling is the same 806.1 MB/token.
- **Weights: different in part.** Byte samples show `o_proj`, the shared `down_proj`
  and the expert `down_proj` edited (4–22% of sampled bytes differ, more in later
  layers). Everything else sampled is byte-identical to the reference. The router
  weights are identical, but the hidden states they see are not, so routing will differ.
- **Generated text will differ.** So this is a different routing workload, and none of
  the "identical tokens" controls used between reference runs apply.

## Central prediction

**Bytes/token: 0 ± 5% against HEAD**, i.e. 247–273 / 268–296 / 294–325 MB. The mechanism
for the delta being small: bytes/token is `806.1 MB × (1 − hit rate)`, and hit rate
follows routing locality across consecutive tokens, which an edit that stays close to
the reference's weights should leave near where it was. **Hit rate within ±3 pp** of
67.7 / 65.0 / 61.6%.

**Falsifier:** bytes/token outside ±5% on any case, or hit rate outside ±3 pp. Either
would mean the edit moved routing locality materially, and the "same speed" claim for
this model would be wrong.

## Not predicted

- **tok/s and `io`.** The artifact is about 0 h old and was written by the installer,
  which writes the layer files scattered. The reference artifact it would be compared
  against is sequentially rewritten and 38 days old. Write order and recency both move
  `io` by more than any expected routing effect, so the tok/s difference is not a
  property of the model and is reported but not claimed.
- **`cb1-wait`**: expected unchanged within the ~5% run-to-run spread, since compute
  per token is identical. A larger move would point to a different generated length.

## Controls

- All three `stop=endOfTurn`. Prompt token counts 61 / 430 / 3,015 (same tokenizer).
- Read all three outputs: reject on a loop, a repeated block or an incomplete end.
- `req/tok` exactly 240.00 (30 × 8).
