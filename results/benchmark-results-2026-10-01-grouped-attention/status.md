# Status: complete on the iPhone (2026-10-02); the Mac arm was not run

The phone A/B finished on 2026-10-02. See `results.md`. What follows is the
pause record from 2026-10-01, kept as it was written.

## Paused 2026-10-01 22:50, with 5 of 8 phone runs done

The iPhone A/B in `predictions.md` was stopped because the phone was needed.
The short and medium pairs are complete. Only one long run finished.

## Arms

- **A**: `810068b` (pre-merge) with the harness commit `016270a` cherry-picked
  onto it. It has the old split-KV full attention.
- **B**: `016270a` (the merge `5820bbd` plus the same harness commit). It has
  grouped full attention.
- Both arms: Release, iOS 26.6, iPhone 17, 24 slots, `--max-new 1024
  --max-context 4096`, prefill chunk `auto`, battery 100%/full, Low Power Mode
  off, apps closed, network on.

The bundles were built in a session scratchpad that no longer exists. To
rebuild them, run `xcodebuild -project iOS/TurboFieldfareiOS.xcodeproj -scheme
TurboFieldfareiOS -configuration Release -destination 'generic/platform=iOS'
-allowProvisioningUpdates build`. Run it once at `016270a` for B, and once with
`810068b` checked out detached and `git cherry-pick -n 016270a` applied for A.
Copy each `TurboFieldfareiOS.app` to `$APPS/A/` and `$APPS/B/`. Keep that
bundle name, because the liveness check matches it.

## Done (ms per decode forward)

| run | text sha256 | bytes/tok | hit | cb1-wait | io | head | wall | tok/s | thermal | compressions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| short-A1 | `d32db73b…` | 160.71 MB | 79.1% | 53.52 | 107.74 | 9.63 | 178.33 | 5.619 | nominal | n/a |
| short-B1 | `d32db73b…` | 160.71 MB | 79.1% | 53.01 | 104.13 | 9.67 | 174.27 | 5.750 | nominal | n/a |
| medium-B1 | `209ffadb…` | 187.08 MB | 75.7% | 63.03 | 126.59 | 10.37 | 208.19 | 4.811 | nominal | 0.89 M |
| medium-A1 | `209ffadb…` | 187.08 MB | 75.7% | 68.28 | 142.11 | 10.61 | 229.67 | 4.361 | nominal | 1.72 M |
| long-A1 | `87f6f357…` | 204.59 MB | 73.4% | 83.52 | 138.04 | 10.00 | 240.50 | 4.165 | nominal | 1.45 M |

Within each pair, the generated text is byte-identical (`cmp` on the saved
`.txt` files), and bytes/token, hit rate and reads/tok match to the digit. That
control held. The partial long-B1 run and the first, falsely failed short-A1
run are in `logs/aborted/`. Neither is scored.

The interim reading is not scored. Short `cb1-wait` moved −0.51 ms against a
predicted 0 ± 1.5. Medium moved −5.25 ms against a predicted −1 to −3, from a
single pair in which the A run had twice the compressor churn.

## Resume

Run all four long runs in one sitting, in A B B A order, so that every long
pair shares the same session. Today's `long-A1` stays in `logs/` as a fifth
long run, and its timestamp tells it apart from the resumed ones.

```bash
APPS=/path/to/bundles SKIP="short-A1 short-B1 medium-B1 medium-A1" \
  results/benchmark-results-2026-10-01-grouped-attention/run-ab.sh
```

That takes about 35 minutes: a 3-minute cooldown, 4 runs of ~4 minutes each,
and 5-minute cooldowns between runs. The phone needs the network on (Airplane
Mode blocks launching free-team apps), other apps closed, and the screen
unlocked. The script leaves arm B installed when it finishes.
