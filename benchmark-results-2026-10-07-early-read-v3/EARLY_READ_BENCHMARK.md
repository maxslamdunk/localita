# Early-read benchmark

This branch adds a decode change: while storage is idle after each layer's
expert reads, read the expert the next layer most likely needs. The benchmark
below measures it with the
[community benchmark](docs/COMMUNITY_BENCHMARKS.md) prompts and settings.

Each of the three cases runs this order twice, after one discarded warmup:

> off, router, fitted, fitted ×2, fitted ×2, fitted, router, off

- **off:** no early read.
- **router:** guess the next layer's expert with that layer's own router.
- **fitted:** guess with a small guess fitted for this model.
- **×2:** read two guessed experts per layer instead of one.

Every comparison (router vs off, fitted vs router, fitted ×2 vs fitted) is
made between runs that sit next to each other, four times per case, so slow
changes in the Mac's speed cancel within each pair. Two runs of the same
setting next to each other show how much identical runs differ.

## What you need

- An Apple Silicon Mac, macOS 26, Xcode 26 / Swift 6.2 or newer.
- About 20 GB free disk, an internet connection for the model download.
- About 3 hours on a 16 GB Mac, 5 on an 8 GB one, with the Mac on power and
  not in use. Overnight is ideal. The script keeps the Mac awake and refuses to
  start on battery or in Low Power Mode.

## Steps

1. Clone this fork and check out this branch:

   ```bash
   git clone https://github.com/maxslamdunk/turbo-fieldfare.git
   cd turbo-fieldfare
   git checkout early-expert-read-benchmark
   ```

2. Install the model (about 15 GB download), per the
   [README](README.md#command-line-interface):

   ```bash
   swift run -c release TurboFieldfareRepack --output scratch/gemma4.gturbo
   ```

   If you already installed it in another checkout, move that
   `scratch/gemma4.gturbo` folder here instead, or pass `MODEL=<its path>`
   to the script.

   **Don't start the benchmark right after installing.** macOS keeps working
   on a freshly written 14 GB for a while; wait until the next day, or at least
   an hour.

3. Build, quit other apps, connect power, and run:

   ```bash
   swift build -c release --product TurboFieldfareCLI
   Scripts/benchmark-early-read.sh
   ```

   Then leave the Mac alone until it finishes. If it stops for any reason, run
   the same command again: finished runs are kept and only the rest run.

4. When it finishes, your browser opens this fork's benchmark issue form with
   every field filled in except **Results**, and Results is on the clipboard.
   Click into the Results field, press **Cmd-V**, check the report, and press
   **Submit**. You can drag `benchmark-results.zip` into the issue too. No
   GitHub account? Send `benchmark-results.zip` to whoever asked you.

   To copy Results again: `pbcopy < benchmark-results/results.md`.
   To open the form again: `open "$(cat benchmark-results/issue-link.txt)"`.

## Ran an earlier version?

The script refuses to mix versions in one folder. Keep the old results under
another name first:

```bash
git pull
swift build -c release --product TurboFieldfareCLI
mv benchmark-results benchmark-results-before-v3
mv benchmark-results.zip benchmark-results-before-v3.zip
Scripts/benchmark-early-read.sh
```

## What is in the results

`benchmark-results/summary.txt` has one line per run: tokens per second, and
for runs with the early read on, how many of each token's expert reads were
already loaded and how often the guess was right. Its last lines check that
every run of a case produced identical text. Each run's `.conditions` file
records power, thermal state, free memory and the busiest processes when it
started.
