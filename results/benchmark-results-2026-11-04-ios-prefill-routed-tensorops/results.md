# Results: prefill's routed experts on the matrix units

Scored against [`predictions.md`](predictions.md), committed first in
`3521aa5`. Its amendment, written after the first quality gate failed and
before the second ran, was committed in `e16599d`. The logs are in
[`logs/`](logs/), and the drivers are `run-ab.sh`, `run-gate.sh`,
`run-gate2.sh` and `run-gate2-b-rerun.sh`, over `lib.sh`. `summarize.py`
prints the A/B figures ([`summary-output.txt`](summary-output.txt)) and
`gate.py` the gates. The device kernel suites are in
[`device-kernel-suites.txt`](device-kernel-suites.txt).

## What was run

- Branch `prefill-port`, iOS app Release, installed over the app.
  - **A/B and first gate:** `030f66b`, which is `e09e293`'s kernels plus the
    harness flags.
  - **Second gate:** `e16599d`, which adds `--score-continuation`.

  One binary per set: arm A is the default (matrix units), arm B is
  `--no-routed-tensorops`.
- iPhone 17, iOS 26.6. `real-generation-v1` prompts, prompt SHA-256 checked
  against the frozen files. 24 slots, `--max-context 4096`, chunk `auto`,
  defaults otherwise. **`--max-new 32`**: only prefill changes, so decode was
  not measured at 1024 tokens.
- **A/B:** 2026-11-04, 21:32–22:28. Long and medium A B B A, short A B, 60 s
  before the first run and 300 s between runs. Battery 100%/full, thermal
  `nominal` at every sample, network on.
- **Gates:** 22:33–23:06 and 23:21–00:25, with thermal reaching `serious`.
  That does not affect what a gate scores. Arm B of the second gate stopped
  at endpoint 19 of 24 when the phone was used and then restarted. It was
  rerun on the long case alone (`gate2-B-r2`), and `gate.py` merges the two
  logs.
- **Device kernel suites (Debug):** 186 tests in 52 suites passed on the A19,
  including the two new FP32-reference tests (aligned, and 2-byte-aligned
  gate/up) and the tile-builder test. On Apple10 the reference test also
  asserts that the matrix-unit path ran.

## Scoring

### Speed (prefill wall from `[prefill-time …]`, seconds)

| case | A | B | change |
| --- | --- | --- | --- |
| long (3015 tok) | 56.25, 54.12 | 66.97, 67.29 | **−11.9 s (−17.8%)** |
| medium (430 tok) | 9.91, 10.37 | 11.77, 11.97 | **−1.73 s (−14.6%)** |
| short (61 tok) | 9.99 | 9.26 | +0.73 s (n=1) |

| GPU routed time | A | B | A/B |
| --- | --- | --- | --- |
| long | 4.31, 4.20 | 22.98, 23.38 | **0.18** |
| medium | 1.05, 1.09 | 3.17, 3.15 | 0.34 |
| short | 0.67 | 0.84 | 0.80 |

- **P1, long GPU routed 3–7 s (A/B 0.13–0.30): held.** 4.20–4.31 s, A/B 0.18.
- **P2, long wall −8 to −14 s: held.** −11.9 s. The routed phase went
  27.6–27.8 → 16.7–17.0 s and is now set by its reads. `fetch` stayed
  15.7–16.2 s, while `drain` (blocked on a tile's GPU work) fell 11.7–12.0 →
  0.7–0.8 s. Storage busy is unchanged (15.6–16.1 s), but its overlap with the
  GPU fell 11.2–11.3 → 3.4–3.6 s: storage is now the phase's critical path.
- **P3, medium GPU routed 0.5–1.3 s and wall −1.0 to −2.5 s: held.**
  1.05–1.09 s and −1.73 s.
- **P4, short within ±1.5 s: held.** +0.73 s on one pair. GPU routed time
  still fell 20%, so on the A19, unlike the M1, even ~4 pairs per expert gain
  on the GPU. The wall difference sits in `fetch`, which on a 61-token prompt
  is mostly the first-touch SHA-256 of the layer files (9.1 against 8.2 s).
  That is storage noise; no threshold is called for.
- **C1, prefill bytes within ±1%: held.**
  - long: 30,561.02 against 30,605.86 MiB (−0.15%, 9,541 against 9,555 reads);
  - medium: 8,882.27 against 8,875.86 (+0.07%);
  - short: 6,953.98 against 6,950.78 (+0.05%).

  The bytes are identical within each arm, so a few routes flip
  deterministically, as predicted.
- **C2, shared expert and attention block unchanged: held.** GPU shared
  16.61–16.78 (A) against 16.57–16.76 s (B), long; GPU attention block 19.1–19.2 (A) against
  20.9–21.3 s (B). That is −9%, inside the ±10% noise band but on the same
  side twice. A smaller resident footprint during attention is a candidate
  cause, unmeasured.
- **C3, B reproduces the breakdown: held.** Long B 66.97 and 67.29 s against
  67.67 s on 2026-11-04 afternoon.
- **Text:** byte-identical across arms for all three cases over 32 tokens
  (`30e14eae…`, `28ca6ef4…`, `d2f79cde…`). This was not predicted; it shows
  only that the first 32 tokens did not cross a tie.
- **Decode:** not measured at 1024 tokens. At 32 tokens long's decode
  bytes/token are 271.03 (A) against 270.72 MB (B). The expert cache decode
  starts from depends on prefill's last reads.

### Quality

**First gate (predictions Q1/Q2): failed.** It used 16 endpoints through
each prompt.
- Mean ΔNLL +0.170 nats and worst 3.55, against limits of 0.01 and 0.05.
- Top-1 disagreed at 4 of 32 endpoints, all with B top-2 gaps above 0.1 nats.

The endpoints lay inside the user turn. There, both arms gave the prompt's own
next word 8–23 nats, and the top-1 was often a word fragment or another
script. The Mac reproduces the phone's values (15.45 against 15.35 nats at
medium endpoint 134), and token-by-token decode (`--prefill off`) gives the
same continuation as prefill ("-thought ownners"). So these distributions are
the model's own, and a rounding-sized change moves them by nats. The gate could
not tell rounding from a defect. It is recorded as failed, not reinterpreted.
At the two full-prompt endpoints, where the model is in distribution, the arms
agreed: same top-5, log-probabilities within 0.04 nats on long.

**Second gate (amendment Q1′–Q3′):** 12 endpoints inside each case's frozen
October reply (old kernels, before this branch), 24 in all.

Output: [`gate2-output.txt`](gate2-output.txt); gate 1's is
[`gate1-output.txt`](gate1-output.txt).

- **Q1′, mean ΔNLL within ±0.02: held.** −0.0012 nats over 24 endpoints.
- **Q2′, |ΔNLL| ≤ 0.10 where B's NLL ≤ 5: held.** All 24 qualify (B's NLL
  0.00–0.75); the worst is 0.037.
- **Q3′, top-1 agreement where B's gap > 0.1: held.** Top-1 agrees at 24 of
  24, including the closest call (gap 0.208, long endpoint 3615).

Gate 1's own thresholds (mean within 0.01, worst within 0.05) also hold on
these endpoints. In the model's own reply the matrix-unit path is
indistinguishable from the old kernels, at the scale of rounding.

## Decision

**Kept, on by default** where the tensor pipelines build, as the predictions
planned once the gate passed. The text change is rounding from reordered
floating-point work, the same kind of change PF-15 and PF-17 shipped with, not
a chosen quality trade. `--no-routed-tensorops` /
`TURBO_FIELDFARE_PREFILL_ROUTED_TENSOROPS=0` turns it off.

The long prompt's prefill is now bounded by storage in its routed phase,
which is what step 3 (layer-at-a-time across chunks, −62% predicted bytes)
addresses.

## Notes

- **The Mac's M1** builds the same tensor pipelines, so the matrix-unit path
  is also the Mac's default. On a 43-token prompt there, routed GPU time rose
  0.88 → 1.70 s with greedy text identical. The M1 has no neural
  accelerators. The Mac is not the target; the M1 long-prompt case is
  unmeasured.
- The activation scratch grows to hold 2048-pair microbatches: +2.8 MB at the
  iOS 1024 chunk, and 17.7 MB against 16.4 MB in total at the Mac's 128.
- Credit: the kernels are adapted from zw5/ane-fieldfare `587953b`
  (Apache-2.0); see `THIRD_PARTY_NOTICES.md`.
