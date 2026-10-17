# Early-read benchmark

This branch adds a decode change: while storage is idle after each layer's
expert reads, read the expert the next layer most likely needs. The benchmark
below measures it with the
[community benchmark](docs/COMMUNITY_BENCHMARKS.md) prompts and settings,
running each case eight times across the setting.

## What you need

- An Apple Silicon Mac, macOS 26, Xcode 26 / Swift 6.2 or newer.
- About 20 GB free disk, an internet connection for the model download.
- About 2–3 hours with the Mac on power and otherwise idle.

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

3. Build, close other apps, connect power, and run:

   ```bash
   swift build -c release --product TurboFieldfareCLI
   Scripts/benchmark-early-read.sh
   ```

4. When it finishes, the script prints a link. Open it: it is this fork's
   benchmark issue form with everything filled in from your runs. Check it and
   press **Submit**. You can drag `benchmark-results.zip` into the issue too.
   No GitHub account? Send `benchmark-results.zip` to whoever asked you.

   If the link does not work, `python3 Scripts/early-read-report.py` prints it
   again, and `benchmark-results/issue.md` has the same report to paste.

`benchmark-results/summary.txt` has one line per run: tokens per second, and for runs with the
early read on, how many of each token's expert reads were already loaded and
how often the guess was right. Its last lines check that every run of a case
produced identical text.
