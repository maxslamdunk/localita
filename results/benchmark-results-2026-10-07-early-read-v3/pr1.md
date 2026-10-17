## Summary

During decode, storage sits idle after each layer's expert reads while the GPU
finishes the layer. This PR uses that time to read one expert of the next layer
early: the highest-scoring one under the next layer's router (run on this
layer's router input) that the next layer's cache doesn't hold. It goes into a
separate staging buffer. If the next layer then misses that expert, the buffer
is swapped into its slot and the read is skipped. Otherwise the read is wasted.

The cache plans exactly as before, so hit rate and generated text don't
change. Unlike the prefetch in CACHE-06, the read starts only after the
layer's own reads finish and never touches the slot pool.

On by default. `--early-expert-read off|router` on the CLI and server. When it
runs, the CLI prints one more line after the footer:
`[early-read needed/tok=… loaded-early/tok=… reads/tok=… precision=…]`.

## Validation

- `swift build -c release`, `Scripts/test.sh`, the SwiftUI macro and Markdown
  link checks. New tests: an adopted early read skips its read and leaves the
  cache consistent; guess selection; the flag on CLI and server; the footer.
- Real model, on five Macs: the `docs/COMMUNITY_BENCHMARKS.md` prompts and
  settings, each case run 16 times in the order off, router, fitted, fitted ×2,
  fitted ×2, fitted, router, off (twice). Each comparison is between adjacent
  runs. `fitted` and ×2 are the follow-up PR. Generated text was identical
  across all 16 runs of each case on every Mac.

## Memory and performance

One 3.36 MB staging buffer and a 512 B score buffer. No model data enters the
Swift heap.

Decode tok/s, router vs off: median change over the 4 adjacent pairs of each
case.

| Mac | short | medium | long | pairs faster |
| --- | ---: | ---: | ---: | ---: |
| M1 MacBook Air, 8 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/5)) | +18.7% | +18.9% | +16.8% | 12 of 12 |
| M1 MacBook Pro, 8 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/7)) | +14.1% | +12.9% | +11.4% | 12 of 12 |
| M1 MacBook Pro, 16 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/4)) | +30.8% | +30.2% | +26.6% | 12 of 12 |
| M3 MacBook Air, 16 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/8)) | +29.1% | +16.2% | +1.0% | 11 of 12 |
| M4 MacBook Air, 16 GB ([report](https://github.com/maxslamdunk/turbo-fieldfare/issues/9)) | +12.5% | +9.8% | +9.9% | 12 of 12 |

Each report has every run, the noise between identical runs, and the
early-read counters.

## Remaining limitations

- On the M3 the long case gained only +1.0%. With two reads per layer (the
  follow-up PR), it gained the most of any case.
- Not in the Mac app's settings; the app runs the default.

- [x] The change does not load a complete checkpoint, shard, or large model
      tensor into Swift heap memory.
- [x] Logs and artifacts contain no credentials, private paths, or model
      weights.
