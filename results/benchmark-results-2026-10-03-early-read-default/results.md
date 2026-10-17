# Check: the early read is on by default

Not an A/B. The decision rests on
[`results/benchmark-results-2026-10-03-ios-fitted-guess`](../benchmark-results-2026-10-03-ios-fitted-guess/results.md).
These two runs check that the defaults, with no environment variables or launch
arguments, load the shipped fitted guess and change no output.

The code is `e4eb3a4`. The fitted guess ships in the runtime's
`NextLayerGuess/` resources and is matched to the model by its manifest
`sourceSnapshotHash`. Only gemma4 has one; other models fall back to the
next layer's router.

| | Mac, short, 16 slots | iPhone 17, short, 24 slots |
| --- | --- | --- |
| guess loaded | bundled (used/tok matches the fitted run) | `gemma-4-26b-a4b-it-4bit.bin@b18242445534d452…` |
| text SHA-256 | `9c3bd04e…`, unchanged | `d32db73b…`, unchanged |
| early reads / used per token | 29.00 / 24.10 | 29.00 / 19.83 |
| reads/tok, bytes/tok | 82.35, 263.79 MiB | 59.34, 190.09 MB |
| tok/s | 3.846 (not a speed figure) | 7.108 (one run) |

Every counter matches the fitted-guess runs to the digit: the Mac `25e15c4`
row and the phone `c3cb85a` short F rows.

The Mac's tok/s is 14% below the earlier fitted run on identical work, and all
of the difference is in `io` (+30.5 ms per forward). It ran straight after a
full test suite on a 97%-full volume. It is not attributed, and it is not a
speed figure.

Files:

- the Mac's stdout and stderr are in [`mac/`](mac/);
- the phone's harness log is beside this file;
- [`pull-log.sh`](pull-log.sh) is the script that copied it off the phone.
