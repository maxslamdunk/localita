# Predictions: supergemma4 on the iPhone, fitted guess against the router

Written 2026-10-04 on branch `supergemma4-next-layer-guess` at `ff605fa`,
before any supergemma4 run on the phone.

## The change

The branch adds supergemma4 to `NextLayerGuess/index.json`, pointing at
gemma4's fitted file. supergemma4's routers are byte-identical to gemma4's,
and on its Mac traces that file scores 0.721 against 0.579 for the router
(`research-results-2026-10-04-supergemma4-next-layer-guess/`). Without the
entry, supergemma4's early read falls back to the next layer's router. This
A/B is what decides whether the branch merges.

## Arms

One Release binary from this branch. supergemma4 is pinned with
`--model-dir supergemma4.gturbo`, and the early read is on in both arms.

- **N:** `--early-expert-guess router`, which is what supergemma4 runs on main
  today.
- **F:** the default, which with the new entry loads gemma4's shipped file.
  The `runner-ready` line names the guess and its SHA-256
  (`b18242445534d452…`).

Protocol: `real-generation-v1`, `--slots 24 --max-new 1024 --max-context
4096`, chunk `auto`, N F F N per case, 300 s cooldown. Count aging is on by
default in both arms, as is `F_NOCACHE`.

This is supergemma4's first phone run, so there is no absolute baseline to
predict against. The predictions are about F against N. The absolute figures
are recorded as a new baseline.

## Predictions

Means of two runs per arm. Footer MB are MiB.

| | short | medium | long |
| --- | --- | --- | --- |
| P2. N live precision (used / early reads) | 0.51–0.59 | 0.53–0.61 | 0.57–0.66 |
| P2. F − N precision | +0.10 to +0.17 | +0.10 to +0.18 | +0.11 to +0.19 |
| P3. F − N used/tok (point) | +3.8 | +4.1 | +4.5 |
| P3. F − N bytes/tok, footer MB | −9 to −15 (point −12.2) | −10 to −16 (−13.1) | −11 to −17 (−14.3) |
| P4. F − N `io` ms/fwd | −4 to −15 | −4 to −15 | −4 to −15 |
| P5. F vs N tok/s | +2 to +9% | +2 to +9% | +2 to +9% |

**P1, identical work (control).** In each case, all four texts share one
SHA-256. Within a case, hit rate and req/tok are identical across arms, and
peak footprint is within 2 MB.

**P3, the arithmetic.** There are 29 early reads per token, one per layer
transition, the same in both arms. A used early read replaces a demand read
one for one. So reads/tok falls by exactly the rise in used/tok, and bytes/tok
by 3.2031 MiB per read. The point values are the offline per-prompt gain
(`cross-score-output.txt`: +0.131 / +0.141 / +0.154) × 29 reads. On gemma4 this
held to within 0.01 reads/tok.

## Mechanism

Precision transfers from the Mac traces, as it did on gemma4. There, the
offline gain added to live N predicted live F to within 0.011 on every case.
More correct guesses mean fewer demand reads at the same hit rate, so `io`
falls and tok/s rises. The ranges follow gemma4's measured N → F results
(`benchmark-results-2026-10-03-ios-fitted-guess/results.md`): precision
+0.134 to +0.146, `io` −6.8 to −14.9 ms, tok/s +4.2 to +13.4%. The long +13.4%
was inflated by GPU speed, so P5's top is lower.

The live precision ranges are wider than gemma4's because count aging is now
on. It changes which experts the cache holds, and so which reads are misses.
The offline replay modelled plain LFU.

## What would falsify it

- **P1:** any text, hit-rate or req/tok difference within a case. The arms
  then did different work, and nothing else counts.
- **P2:** F − N below +0.07 on two or more cases. The Mac traces did not
  transfer to supergemma4 on the phone.
- **P3:** reads/tok not falling by the rise in used/tok to within 0.05. Either
  something other than the guess changed, or the accounting is wrong.
- **P5:** tok/s falling on two or more cases where `head`'s `[gpu-time …]`
  figures are within 5% between arms.

## Decision rule

If P1 holds and P2 and P3 hold on at least two cases, merge the branch.
supergemma4 then gets gemma4's file by default. P5 is reported, but because of
the GPU-speed noise it does not decide the merge on its own: P3 shows the
mechanism. If P2 fails, leave the branch unmerged and record why.
