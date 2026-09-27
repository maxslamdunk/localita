# Results: SuperGemma 4 on `real-generation-v1` (Mac)

Scored against `predictions.md`, which was committed first (`08e00dd`). Binary:
`.build/release/TurboFieldfareCLI` built from `6266f48`'s runtime; the branch changes
touch only the installer and the app layers, not the CLI's path. Model
`scratch/supergemma4.gturbo`, installed 2026-09-27 22:25 and run about 1 h later.
`--verify-install` clean: 37 files, 14,291,913,097 bytes. AC power, Spotlight indexing
off, preflight clean, memory 51% free before the run, data volume 34 GiB free.

The footer prints MiB labelled MB; figures below are MiB unless marked.

| | short | medium | long |
| --- | --- | --- | --- |
| prompt / new tokens | 61 / 513 | 430 / 728 | 3,015 / 555 |
| stop | endOfTurn | endOfTurn | endOfTurn |
| bytes/token | **245.78** | **262.13** | **293.56** |
| vs HEAD reference (248.10 / 268.84 / 294.93) | **−0.9%** | **−2.5%** | **−0.5%** |
| hit rate | **68.0%** | **65.9%** | **61.8%** |
| vs HEAD (67.7 / 65.0 / 61.6%) | +0.3 pp | +0.9 pp | +0.2 pp |
| req/tok | 240.00 | 240.00 | 240.00 |
| tok/s | 3.555 | 3.159 | 2.776 |
| vs HEAD (3.729 / 3.255 / 2.897) | −4.7% | −2.9% | −4.2% |
| `io` ms/fwd | 161.81 | 180.67 | 206.62 |
| `cb1-wait` ms/fwd | 95.72 | 111.95 | 130.96 |
| `head` ms/fwd | 15.04 | 14.91 | 13.91 |
| wall ms/fwd | 281.82 | 316.95 | 360.89 |
| fetch GB/s (bytes ÷ `io`) | 1.593 | 1.521 | 1.490 |

Warmups produced the same token counts and the same bytes/token and hit rate to the
digit (tok/s 3.431 / 3.180 / 2.863), so the measured runs are the same routing workload
as their warmups.

## Scoring

- **Central prediction held.** Bytes/token 0 ± 5% (measured −0.5% to −2.5%), hit rate
  ±3 pp (measured +0.2 to +0.9 pp). Routing locality is essentially unchanged by the
  edit, so on this layout the model costs the same bytes per token as the reference.
- **Controls held.** All `stop=endOfTurn`, prompt tokens 61 / 430 / 3,015 (same
  tokenizer), req/tok exactly 240.00. All three outputs are coherent, complete, and have
  no repeated lines.
- **tok/s: not claimed, as stated in advance.** The 3–5% deficit sits in `io`
  (+4.6 / +1.8 / +5.5%) on an artifact written scattered by the installer an hour
  earlier, against a reference artifact that was rewritten sequentially and is 39 days
  old. Achieved fetch 1.49–1.59 GB/s against the reference's 1.58–1.68.
- **`cb1-wait` moved more than expected: +6.7 / +6.6 / +4.6%** against HEAD, against a
  prediction of "within ~5%". Compute per token is identical by construction, and the
  generated text differs (513 / 728 / 555 new tokens against 527 / 665 / 597), which
  changes the KV lengths attention runs over, but the medium case's longer output does
  not explain the short case's move. **Unattributed.** The 4.7% spread recorded for `cb1-wait`
  between identical-token runs of one binary on 2026-09-15 covers the long case only;
  short and medium sit about 2 points outside it. Not a model property until reproduced.

## Not tested

- The iPhone. The device was not connected; nothing here measures the phone.
- Output quality beyond "coherent and complete". No refusal or capability evaluation
  was run on either model.

## Correction to the predictions file

`predictions.md` calls the reference artifact 38 days old. Written 2026-08-19 and run
against on 2026-09-27, it is 39. Left as committed, since it was written before the run.
