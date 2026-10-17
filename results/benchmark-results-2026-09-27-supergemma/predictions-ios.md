# Predictions: SuperGemma 4 on the iPhone 17

Written before any device run of this checkpoint, after the Mac run in `results.md`.
Build: branch `supergemma-model`, Release, installed over the existing app. Model:
the Mac's verified `supergemma4.gturbo` pushed into the app container with
`devicectl device copy to`, so its write order on the phone is devicectl's and it is
about 0 h old. Protocol as in `results/benchmark-results-2026-09-24-ios-24slots/`:
`--autorun --case <id> --slots 24 --max-new 1024 --max-context 4096`, plus
`--model-dir supergemma4.gturbo`.

Comparison: the reference model's 2026-09-24 rows at 24 slots, bytes/token
**160.71 / 187.08 / 204.59 MiB**, hit rate **79.1 / 75.7 / 73.4%**.

## Central prediction

**Bytes/token 0 ± 5%, hit rate within ±3 pp** of those rows. On the Mac at 16 slots the
same checkpoint came in at −0.5 to −2.5% and +0.2 to +0.9 pp, so the routing-locality
argument has already survived one test; at 24 slots the hit rate is higher and the
absolute bytes lower, so the relative band is kept rather than tightened.

**Falsifier:** any case outside ±5% bytes/token or ±3 pp hit rate.

## Not predicted

- **tok/s and `io`.** The device's fetch rate moved by up to 29% between byte-identical
  runs on 2026-09-24 (compressor churn and thermal state), and the artifact's age and
  write order differ from the reference's. Reported, not claimed.

## Controls

- All three `stop=endOfTurn`; prompt SHA-256 matching the canonical hashes; each log
  states `slots=24`.
- Peak footprint within ±50 MB of the reference rows (3.109 / 3.234 / 3.378 GB): the
  model's resident size and layout are identical, so memory should not move.
- Thermal state recorded beside every row.
