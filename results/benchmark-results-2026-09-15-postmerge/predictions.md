# Predictions — post-merge baseline (upstream 0.8.0)

Written before any model run on this binary. Binary: `.build/release/TurboFieldfareCLI`
built 2026-09-15 20:21 from the merged tree; `swift build` at HEAD `4056bfa` was a
no-op (`796b79c` is the merge, `4056bfa` is docs-only). Comparison baseline: the
`results/benchmark-results-2026-09-15-t26d/` run ~1 h earlier on the old binary (built
2026-08-10 19:52). Same artifact (2026-08-19 sequential rewrite, untouched, layer
mtimes 2026-08-19 22:39–22:40), same manifest hash, same prompts and seeds, AC power,
Low Power Mode off, Spotlight indexing disabled on the data volume, volume 75% full
(51 GiB free; 74% / 53 GiB at the earlier run).

## What the merge changed on this protocol's path

- **#159, prefill attention.** The `supportsFamily(.apple10)` gate on the TensorOps
  2D full-attention prefill pipeline was removed. Production defaults to
  `.fullTensorOps2DPreferred`, so this M1 — which previously fell back to
  causal-tiled — now runs TensorOps for full-attention prefill layers if the
  pipeline builds. That reorders float work inside prefill and therefore changes
  the KV cache and prefill hidden states by small amounts. Decode kernels untouched.
  Also sets `AGX_RELAX_CDM_CTXSTORE_TIMEOUT=1` before device creation (relaxes a
  driver watchdog deadline).
- **#118, detokenization.** Drops `clean_up_tokenization_spaces`. stdout text can
  differ from the old binary with **identical tokens** — whitespace before
  punctuation and around quotes. stdout byte-identity is therefore not a valid
  control across this merge.

## Controls (a miss invalidates the run)

- Prompt tokens 61 / 430 / 3,015; all `stop=endOfTurn`.
- stderr records which prefill path ran: a `PrefillAttention: TensorOps 2D pipeline
  unavailable` line means fallback (prefill math unchanged); its absence means
  TensorOps ran.

## Central prediction

**Bytes/token: 0 delta.** Decode reads and cache planning are untouched.

1. **Tokens identical on all three cases** despite #159: generated 511 / 669 / 604,
   and bytes/tok **249.72 / 265.90 / 291.42 MiB**, hit rate **67.5 / 65.4 / 62.1%**,
   req/tok **240.00**, reads/tok **77.96 / 83.01 / 90.98** — to the digit. stdout
   diffs against t26d, if any, confined to whitespace adjacent to punctuation or
   quotes (#118).
2. **Prefill expert bytes within ±1%** of 6,944.38 / 25,496.88 / 183,663.98 MB
   (exact identity not required: prefill routing sees the changed attention output).
3. **Decode timing within noise of t26d:**
   - tok/s ±3%: short **3.63–3.86**, medium **3.25–3.45**, long **2.90–3.08**.
   - `cb1-wait` ±3% of 91.55 / 107.54 / 128.57 ms/fwd.
   - `io` ±5% of 150.18 / 166.39 / 182.59 ms/fwd; fetch GB/s correspondingly
     1.66–1.83 / 1.59–1.76 / 1.59–1.76.
   - `head` ±3% of 15.09 / 15.24 / 14.15.
4. Prefill timing: **not predicted, not comparable** across the merge (#159).

## What each outcome means

- **All within bands** → the merge is decode-neutral on this host. The 26.8 d
  figures stand as the steady-state rate for the new binary; later experiments
  baseline against these rows.
- **Tokens diverge** (any change in generated count, bytes/tok, or a stdout diff
  beyond #118 whitespace) with TensorOps active → attributable to #159 prefill
  numerics, a METH-01 near-tie crossing, not a decode regression. That case's
  timing is a different routing workload and is not comparable; flag for a
  quality check, do not score its timing.
- **Tokens identical, tok/s below band, `cb1-wait` up** → GPU-side change from the
  merge (Metal context / AGX environment). Investigate before any further work.
- **Tokens identical, `io` outside band, `cb1-wait` flat** → storage state, not
  the merge.

## Outcome (appended after the run, 2026-09-15 21:28)

| Prediction | Measured | Verdict |
| --- | --- | --- |
| Prompt tokens 61 / 430 / 3,015, all `endOfTurn` | identical, all `endOfTurn`, six exits 0 | held (control) |
| Which prefill path ran | no fallback line in any of six stderr files → **TensorOps ran** | recorded |
| Generated tokens 511 / 669 / 604 | **527 / 665 / 597** | **missed, 3 of 3** |
| Bytes/tok 249.72 / 265.90 / 291.42 MiB, to the digit | 248.10 / 268.84 / 294.93 (−0.65 / +1.11 / +1.20%) | **missed** (follows the new text) |
| stdout diffs confined to #118 whitespace | real divergence from ~word 50 on short; all three coherent and complete | **missed** |
| Prefill expert bytes ±1% | +0.09 / −0.09 / −0.06%; reads 2,170 / 7,953 / 57,307 | held |
| tok/s ±3% | −0.4 / −2.7 / −3.0% (long 2.897 vs band floor 2.90) | not scored — workload changed |
| `cb1-wait` ±3% | −2.0 / −2.4 / −2.6% | within band; not scored |
| `io` ±5% | +3.0 / +6.6 / +7.3% | medium/long outside; not scored |
| `head` ±3% | +0.2 / +0.5 / −1.3% | within band |

The branch that fired: **tokens diverge with TensorOps active.** Prefill routing
moved before any token was sampled, which places the change upstream of decode and
is consistent with #159. **Attribution is not confirmed**: no CLI, server or app
control reaches `RuntimeConfiguration.prefillAttentionPath`, so a causal-tiled run
needs a code change, and a prompt-encoding change with an identical token count is
not excluded.

Replacement control, since cross-binary stdout identity no longer holds: warmup and
measured stdout are **byte-identical on all three cases** within this binary.

Found while scoring: the ±5% `io` band was tighter than run-to-run noise.
Same-binary warmup → measured `io` on identical tokens moved −6.1 / +0.6 / +2.5%
(old binary) and −1.8 / +4.7 / +5.1% (new binary). Cross-binary `io` movement
(+3.0 to +7.3%) is at the edge of that spread and is not attributed to the merge.
`cb1-wait` fell on all three cases (consistent sign) but inside its own same-binary
spread of up to 4.7%; not claimed.
