# Background probes — predictions (written before any run)

Question from the user, 2026-10-09: can a reply keep generating with the app
in the background or the phone locked? Decode submits GPU work every token, and
iOS refuses GPU work from a backgrounded app. CPU inference is ruled out by the
user. These are capability probes, not performance changes; the predictions
are recorded so the results can be scored against them.

Instrument: `iOS/TurboFieldfareiOS/BackgroundProbe.swift`, launched with
`--background-probe`. One fsynced line per event and per 2 s beat in
`Documents/decode-background-probe-<stamp>.log`. Core ML model from
`make_ane_probe_model.py` (8 × 1024-channel 1×1 conv over 512 positions, FP16).

| # | Probe | Prediction | Falsified by |
| --- | --- | --- | --- |
| 1 | `BGTaskScheduler.supportedResources` on iPhone 17, iOS 26.6 | no `.gpu` (Apple DTS: M3+ iPads only) | `gpu=true` in `supported-resources` |
| 2a | GPU blit in the background under a continued-processing task | refused: status 5 (error), IOGPU "background execution not permitted" | a status-4 beat while `app=background` |
| 2b | Core ML `.cpuAndNeuralEngine` in the background | runs, and on the Neural Engine: background ms within 2× of the foreground NE time, well under the CPU-only time (low confidence: one forum report of Core ML on a locked phone since 18.2) | errors, or times near the CPU-only reference |
| 3 | Model held at chat footprint (~3.3 GB, slots warmed) under the task, other apps in use | killed within a few minutes of heavy app use (camera, Safari); survives idle lock | beats continuing through 5+ min of heavy use, or a kill with the phone idle |
| 4a | Proximity sensor covering the screen | app stays `active`, GPU status 4 throughout | `app=background` or a refused blit while covered |
| 4b | Picture in Picture active, app in the background | GPU refused, like 2a (FB11709596 report) | a status-4 beat with `pip=true app=background` |
