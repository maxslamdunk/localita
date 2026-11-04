# Predictions: prefill's routed experts on the matrix units

Written before any phone run of the change (`e09e293`, harness flag
`0b422b5`), and committed before the runs that score it.

## The change

Prefill's routed experts move from the thread-per-row kernels to two
tensor-op kernels ported from zw5/ane-fieldfare `587953b`:

- same-expert tiles of up to 32 token–expert pairs;
- 32×64×32 `matmul2d` with FP32 accumulation;
- FP16 activations carried at a power-of-two scale per pair and 64-row block;
- microbatches of up to 2048 pairs.

`--no-routed-tensorops` keeps the old kernels, so both arms are one binary.

Baseline, from `results/benchmark-results-2026-11-04-ios-prefill-breakdown/`
(hashed load, as the benchmark runs):
- **long:** wall 67.67 s; GPU routed 23.30 s; routed phase wall 27.84 s; storage busy 15.83 s;
- **medium:** wall 12.15 s; GPU routed 3.17 s.

Nothing was measured on the phone before writing this. One Mac observation
came before it: on the M1 a 43-token prompt's routed GPU time *rose* from 0.88
to 1.70 s, with identical greedy text.

## Runs

- **A/B:** A = default (matrix units), B = `--no-routed-tensorops`. Long and
  medium A B B A, short A B. `--max-new 32`, because only prefill changes.
  Otherwise the protocol: 24 slots, `--max-context 4096`, chunk `auto`,
  300 s cooldowns.
- **Quality gate:** `--session medium-review,long-synthesis
  --score-endpoints 16`, once per arm. That is 16 endpoints spread through
  each prompt, ending at the full prompt.

## What moves

| | B (predicted ≈ baseline) | A, predicted |
| --- | --- | --- |
| P1 long, GPU routed | ~23 s | **3–7 s** (A/B 0.13–0.30) |
| P2 long, prefill wall | ~68 s | **−8 to −14 s** (54–60 s) |
| P3 medium, GPU routed | ~3.2 s | 0.5–1.3 s |
| P3 medium, prefill wall | ~12 s | −1.0 to −2.5 s |
| P4 short (61 tok), GPU routed | ? | −40% to +80% (unsure) |
| P4 short, prefill wall | ? | within ±1.5 s |

## Mechanism

Each 32-pair tile dequantizes an expert's weights once and runs them on the
A19's matrix hardware. Today every pair re-reads and re-dequantizes the
expert's rows in a scalar GEMV. ane-fieldfare measured 6.6× on routed GPU time
(M5, 4,230 tokens).

The long prefill's routed phase is GPU-bound (23.3 of 27.8 s). Once its GPU
time falls below the storage time of its reads (~16 s busy), storage sets the
phase's length. So the wall saves less than the GPU does. Other phases do not
change.

Short prompts give each expert ~4 pairs, so tiles run mostly empty and the
win may vanish or reverse, as on the M1.

## Controls

- **C1:** prefill bytes per case within ±1% of B. Routing in later layers
  sees slightly different hidden states, so a few near-tie routes may flip.
- **C2:** GPU shared expert and attention block unchanged, within ±10%
  (run-to-run GPU spread).
- **C3:** the B arm reproduces the breakdown's numbers, long within ±8%.
- **Text:** not expected to be byte-identical, which is why the quality gate
  exists.

## Quality gate

- **Q1:** over the 32 scored endpoints, the mean ΔNLL (A − B) is within
  ±0.01 nats, and every endpoint's |ΔNLL| ≤ 0.05 nats.
- **Q2:** top-1 agrees at every endpoint where B's top-2 gap exceeds
  0.1 nats.

## What would falsify it

- Long GPU routed A/B above 0.5, or a long wall saving under 4 s.
- Prefill bytes moving more than 1%, which would mean routing changed beyond
  rounding.
- Q1 or Q2 failing.
- A short-case regression over 1.5 s. That would not reject the change, but
  it would call for a pairs-per-expert threshold before the default stays on.

## Amendment, before a second gate (written after the first gate failed)

The first gate ran as specified above, and **Q1 and Q2 failed**: mean ΔNLL
+0.170 nats, worst 3.55, top-1 differing at 4 of 32 endpoints. It is scored as
failed in `results.md`. Its endpoints sat inside the user turn. There, both
arms give the prompt's own next word 8–23 nats, and the top-1 is often a
fragment or another script. The Mac gives the same values (15.45 against the
phone's 15.35 nats at medium endpoint 134), and so does token-by-token decode
with `--prefill off` ("-thought ownners" both ways). So these are the
model's own near-degenerate distributions, not a kernel fault, and a gate
placed there cannot tell rounding from a defect. At the two full-prompt
endpoints, where the model is in distribution, the arms agree: same top-5,
log-probabilities within 0.04 nats on long and 0.09 on medium.

The second gate scores where the model is in distribution: its own reply.
`--score-continuation --score-endpoints 12` appends each case's frozen
October reply to its prompt. That is the old-kernel output before this
branch, `87f6f357…` (long) and `209ffadb…` (medium), pushed as
`<case>-continuation.txt`. The endpoints are placed inside the reply. One
process per arm, A then B.

- **Q1′:** over the reply endpoints of both cases, the mean ΔNLL (A − B) is
  within ±0.02 nats.
- **Q2′:** |ΔNLL| ≤ 0.10 nats at every endpoint where B's NLL is ≤ 5 nats.
- **Q3′:** top-1 agrees at every endpoint where B's top-2 gap exceeds
  0.1 nats.

Any of these failing keeps the change opt-in. The thresholds are looser than
Q1/Q2 on purpose: the full-prompt endpoints already moved by up to 0.04 nats
on the top token.
