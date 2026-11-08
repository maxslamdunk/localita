# Skipping a missed expert on the phone: predictions

Written 2026-11-08, before any phone run of the switch. The change under test is
`--expert-skip miss:0.08` (`TURBO_FIELDFARE_EXPERT_SKIP`, `ExpertSkipPolicy`). In
decode, it drops a routed expert that would be a cache miss and weighs under 0.08
of the layer's top 8. Prefill is untouched. On the Mac it cut the reads a token
waits for by 39.1% (38.00 → 23.14 per token) at KL 0.0246, about half the cost
of one INT4 rounding of the routed experts
(`results/research-results-2026-10-04-lossy-experts/`). None of the later
variants scored better (`results/research-results-2026-11-04-miss-skip-variants/`).

This measures what that is worth in tok/s on the iPhone 17. **It is a
quality-changing experiment, opt-in.** No default changes on its result alone.

## Protocol

- **Hardware and build:** iPhone 17, one Release build installed over the app.
- **Prompts:** `real-generation-v1` `short-explanation`, `medium-review` and
  `long-synthesis`, at `--slots 24 --max-new 1024 --max-context 4096`, chunk
  `auto`. All other settings are defaults: early read on with the fitted guess,
  `F_NOCACHE`, count aging.
- **Arms:** A is the default. B adds `--expert-skip miss:0.08`.
- **Order:** A B B A per case, with 300 s cooldowns. `run-ab.sh` drives it.
- **Reference point, not a control:** the 2026-10-08 one-read arm
  (`results/benchmark-results-2026-10-08-ios-early-read-x2/`) ran at 6.95 / 5.13
  / 5.60 tok/s, with 29.95 / 37.13 / 41.88 foreground reads per token (all reads
  minus 29.00 early) and `io` 82 / 106 / 101 ms. Today's A arm is the baseline.

## What moves

All figures are B against A, per case, from the mean of each arm's two runs.

| Metric | short | medium | long |
| --- | --- | --- | --- |
| Foreground reads per token | −30 to −45% | −30 to −45% | −30 to −45% |
| Bytes per token | −15 to −30% | −15 to −30% | −15 to −30% |
| Hit rate | +4 to +8 points | +4 to +8 points | +4 to +8 points |
| `io`, ms | −25 to −45% | −25 to −45% | −25 to −45% |
| tok/s | **+15 to +35%** | **+15 to +35%** | **+15 to +35%** |

**Mechanism:**

- **Reads:** the Mac transcripts ran at hit rate 76.2%, inside the phone's
  73–79%. So the share of misses under weight 0.08 should be close to the Mac's
  39%.
- **Bytes:** each dropped read is 3,358,720 B (3.20 MiB). The early read stays
  at 29.00 per token and is not cut, so bytes fall by less than foreground reads
  do. On the Mac it was −22%.
- **Hit rate:** a dropped expert is never loaded, so it neither evicts nor counts
  as a miss. The Mac went from 76.2% to 82.2%.
- **`io` and tok/s:** storage reads serially at 2.1–2.2 ms a read and `io` is
  60% of each token. So `io` should fall roughly with the foreground reads, and
  wall time by about that many milliseconds. At the reference point that is
  about −32 to −40 ms of 144–197 ms, or about +20 to +28% tok/s. The range is
  wider for run noise (about 8%) and for `io` not being purely proportional to
  reads.

## Controls

These should not move, or should move exactly as stated:

1. **Early reads per token stay 29.00** in both arms.
2. **Prefill bytes are identical** between the arms, in each case, because the
   policy does not touch prefill.
3. **Generated text is byte-identical within an arm** (A1 = A2, B1 = B2, by
   SHA-256), because sampling is seeded. It **differs between the arms**,
   because B drops experts.
4. **The runner-ready line** says `expertSkip=off` in A and `expertSkip=miss:0.08`
   in B. B's logs also carry an `expert-skip` line.
5. **`cb1-wait` within ±15%,** read beside `head`'s `[gpu-time …]`. GPU speed can
   swing up to about 40% between runs, so a change here is noise unless the GPU
   figures agree.

Generation lengths can differ between the arms, because the text differs, so
the long case may compare runs at somewhat different context lengths. The
report gives each run's new-token count.

## What would falsify it

- **tok/s gains under +10% in any case** while foreground reads fall at least
  30%. That would mean phone `io` does not scale with reads the way the serial
  storage model says.
- **Foreground reads fall less than 25% or more than 50%.** The Mac's cut would
  then not carry over.
- **Any control fails,** in particular a B run without `expertSkip=miss:0.08` in
  its log.

## Quality

The phone gives no KL. Quality was measured on the Mac. The B texts are kept and
read beside the A texts. A clearly broken reply (repetition, wrong language, a
dropped requirement) is reported as a failure of the change, whatever tok/s says.
