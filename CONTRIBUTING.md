# Contributing

Localita is an iPhone app and the engine under it, a port of
[TurboFieldfare](https://github.com/drumih/turbo-fieldfare). Bug reports,
fixes and speed work are all welcome.

## Reporting a bug

Open an issue with the bug template. Say which iPhone and iOS version you
use, which commit you built, and which build of the model is installed. Leave
out chat text you would not want to be public.

For a security problem, don't open an issue. See [`SECURITY.md`](SECURITY.md).

## Before you start

[`AGENTS.md`](AGENTS.md) is the project's guide, for people and coding agents
alike. It has the goal, where the time goes on the phone, the safety rules,
and which tests to run for which change. Read the parts that match your
change.

Two rules are easy to break and expensive when broken:

- **Never load a whole model, shard, expert or source tensor into memory.**
  Weights are memory-mapped, and experts are read into fixed slot buffers.
- **When testing on a phone, install over the app; never delete it.** The
  downloaded model lives in the app's data, and deleting the app deletes it.

The engine is shared with upstream, and this repository merges from it. If a
change to the engine helps the Mac too, it can also go upstream, following
[upstream's contributing guide](docs/UPSTREAM_CONTRIBUTING.md).

## Building and testing

To build the app, see [Build it](README.md#build-it) in the README. Changes
under `iOS/` are tested by building the app; the package tests don't reach
that code.

For the shared code and the Mac side:

```bash
swift build -c release
Scripts/test.sh                       # the full suite, about 6.5 minutes
Scripts/test.sh --filter <suite>      # one suite, while you work
ruby Scripts/check_swiftui_macros.rb --self-test
ruby Scripts/check_markdown_links.rb
```

None of these download or load the model. CI runs them on every push.
[Which tests to run](AGENTS.md#which-tests-to-run) says what a given change
needs locally.

## Speed changes

A change meant to make the engine faster or smaller is measured on an iPhone,
against a prediction written before the run:

1. In `results/benchmark-results-<date>-<topic>/predictions.md`, write what
   should move and by how much, what should not (bytes per token, hit rate,
   and the generated text, by SHA-256), why, and what would prove it wrong.
   Commit it before the run.
2. Run the three benchmark prompts on the phone, in A B B A order, as
   [Measuring on the phone](AGENTS.md#measuring-on-the-phone) describes.
3. Score the prediction in `results.md` beside it, and add the runs to
   [`MEASUREMENTS.md`](MEASUREMENTS.md). Misses are kept too.

Changes that trade output quality for speed, such as fewer experts per token,
are welcome as opt-in experiments, with the quality cost measured.

A change to a `.metal` shader needs a kernel test against the CPU reference,
and the device kernel suites passing on an iPhone ([Shaders](AGENTS.md#shaders)).

## Benchmark results

To share how your iPhone runs the model, run the benchmark in the app and tap
**Send**. You don't need to open an issue. Accepted results are published in
[`benchmark-submissions/`](benchmark-submissions/).

## Pull requests

Keep each pull request to one change, and add a focused test for any change in
behavior. The template asks what you ran and what is left. By contributing,
you agree that your work is licensed under the
[Apache License 2.0](LICENSE).
