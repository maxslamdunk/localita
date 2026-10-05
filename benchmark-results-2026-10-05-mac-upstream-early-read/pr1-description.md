## Summary

During decode, storage sits idle after each layer's routed-expert reads, while
the GPU finishes the layer and starts the next. This PR uses that time to read
one expert of the next layer early: the highest-scoring one, under the next
layer's router applied to this layer's router input, that the next layer's
cache does not hold. It goes into a separate staging buffer. If the next layer
then misses that expert, the buffer is swapped into the slot the cache plan
assigned and that read is skipped; otherwise the read is wasted.

It is not the prefetch rejected in CACHE-06: the early read starts only after
the layer's own reads finish, never touches the slot pool before the plan
assigns a slot, and the cache plans exactly as before. Generated text and hit
rate are unchanged.

On by default; `--early-expert-read off|router` on the CLI and server. When it
runs, the CLI prints one more line after the footer:
`[early-read needed/tok=… loaded-early/tok=… reads/tok=… precision=…]`.

## Validation

- `swift build -c release`, `Scripts/test.sh` (1,825 tests), the SwiftUI macro
  checks and the Markdown link check. New tests: staged-read adoption skips the
  read and keeps the cache consistent, guess selection, the flag on CLI and
  server, the footer line.
- Real model: `docs/COMMUNITY_BENCHMARKS.md` unchanged, with each case run six
  times as off, router, router, off, … (script below).

## Memory and performance

One 3.36 MB staging buffer and a 512 B score buffer; no model data enters the
Swift heap. M1 MacBook Air 8 GB, 16 slots:

| | short | medium | long |
| --- | --- | --- | --- |
| tok/s off → router | TBD | TBD | TBD |
| experts needed from disk per token | TBD | TBD | TBD |
| already loaded when needed | TBD | TBD | TBD |
| precision | TBD | TBD | TBD |
| output identical | TBD | TBD | TBD |

Every correct guess is a read the token no longer waits for; every wrong one is
an extra 3.36 MB read in otherwise idle storage time.

## Remaining limitations

- One read per layer, chosen from the idle time measured on an iPhone 17.
  `TURBO_FIELDFARE_EARLY_EXPERT_READS=2` (experimental, up to 8) tries more on
  faster storage; untested.
- Measured on M1 only so far; community runs on other Macs welcome.
- Not exposed in the Mac app's settings; the app runs the default.

- [x] The change does not load a complete checkpoint, shard, or large model
      tensor into Swift heap memory.
- [x] Logs and artifacts contain no credentials, private paths, or model
      weights.
