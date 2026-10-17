# Results: expert-cache count aging, as an app session on the iPhone

Scored against [`predictions.md`](predictions.md), committed in `26205db`
before any phone run. The model pin was added in `97a00d3`, also before the
runs. The phone build is `dfc4470`, Release. Logs are in [`logs/`](logs/),
the driver is [`run.sh`](run.sh) ([`driver.log`](driver.log)), and
[`summarize.py`](summarize.py) prints the tables
([`summary-output.txt`](summary-output.txt)).

## Answer

**Aging made a session of 11 chats 23% faster on the phone, with identical
output.** Over the whole session:

- decode went from 4.73 to 5.83 tok/s;
- hit rate rose 7.7 points;
- bytes/token fell 18.5%.

Every case gained except the first, which has no earlier chat to be stale
about and gained about 1 point, as predicted.

| whole session | A, counts never age (today) | B, aging | B − A |
| --- | --- | --- | --- |
| decode tok/s | 4.734 | **5.828** | **+23.1%** |
| hit rate | 67.67% | **75.39%** | **+7.7 points** |
| bytes/token (MiB) | 266.23 | 217.03 | −49.2 (−18.5%) |
| reads/token | 83.12 | 67.75 | −15.4 |
| early reads used/token | 23.48 | 20.30 | −3.2 |
| `io` ms/forward | 130.38 | 95.76 | **−34.6** |
| wall ms/forward | 211.69 | 171.93 | −39.8 |
| `cb1-wait` ms/forward | 62.69 | 58.72 | −4.0 |
| head GPU ms/forward | 10.43 | 9.74 | −0.7 |
| session duration, min | 22.7, 23.1 | 18.8, 19.1 | −17% |
| prefill MiB per session | 93,935 | 99,752 | **+6.2%** |

Means of two sessions per arm, weighted by decode tokens. The two runs of each
arm match each other exactly on every cache counter.

Per case, A → B (means):

| case, in session order | hit rate | tok/s |
| --- | --- | --- |
| val-logic-grid (first) | 69.7 → 70.8 (+1.1) | +5.0% |
| val-rust-borrow | 68.2 → 75.8 (+7.6) | +22.0% |
| val-sql-debug | 69.0 → 73.1 (+4.1) | +12.8% |
| val-es-recipe | 68.8 → 81.2 (+12.4) | +32.7% |
| val-compare-table | 66.7 → 77.1 (+10.4) | +40.5% |
| val-fr-translate | 61.8 → 74.3 (+12.5) | +33.7% |
| val-multi-turn | 69.6 → 73.9 (+4.3) | +5.9% |
| short-explanation | 66.4 → 79.5 (+13.1) | +44.5% |
| medium-review | 71.7 → 75.5 (+3.8) | +15.2% |
| long-synthesis | 69.7 → 73.3 (+3.6) | +16.1% |
| val-dialogue | 62.8 → 74.8 (+12.0) | +35.5% |

## What was run

- **Build:** branch `worktree-cache-policy-sim` at `dfc4470`, Release,
  installed over the app.
- **Arms:** one binary. A = `--no-expert-cache-aging`, B =
  `--expert-cache-aging`, and each log's `runner-ready` line says
  `expertCacheAging=` accordingly.
- **Session:** `--session` with the 11 prompts in `predictions.md` order,
  gemma4 pinned with `--model-dir gemma4.gturbo`, 24 slots,
  `--max-new 512 --max-context 4096`, chunk `auto`.
- **Other defaults:** early read with the fitted guess, `F_NOCACHE`.
- **Device:** iPhone 17, iOS 26.6.

**Run order:**

- **A1** at 20:28 local.
- **The first B1 is void.** Launched at 20:56, the app stopped logging 343 s
  in, during the fourth chat. It was still alive but suspended, and from about
  the same time the Mac could not mount the phone's developer disk image
  (CoreDevice error 12040). A replug and a wait cleared the error. The log is
  kept as `logs/void-suspended-decode-sess-B1-…` and scored nowhere.
- **The rerun:** B1 at 22:13, B2 at 22:37, A2 at 23:13.

All arms had 300 s cooldowns. A1 is earlier than the other three by about two
hours, so the order is A, gap, B B A.

**Conditions:**

- **Charging:** battery was 100% charging for A1 and 100% full for B1 and B2.
  A2 ran at 80% unplugged, because the replug left the phone off the charger.
- **Thermal:** every run reached `serious`. A1 and B1 spent about a quarter of
  their samples there, and A2 and B2 more than half. The arms are balanced:
  each has one cooler run and one hotter one.

## Scoring

1. **Hit rate +6 to +11 points: held.** +7.7. A at 67.7% (predicted 63–69%),
   B at 75.4% (73–78%). The replay said 66.5% → 75.7%.
2. **bytes/token −45 to −65 MiB: held.** −49.2. A at 266.2 (255–290), B at
   217.0 (205–235).
3. **Early reads used −2 to −5 per token: held.** −3.2.
4. **`io` −25 to −45 ms/forward: held.** −34.6.
5. **tok/s +12 to +30%: held.** +23.1%.
   - The head's GPU time was 0.7 ms (6.6%) lower in B, so a small part of the
     gain may be GPU speed.
   - `io` alone accounts for −34.6 of the −39.8 ms of wall. With A's wall less
     only that, the gain is still +19.5%.
   - Both B runs beat both A runs, at a whole-session tok/s spread of 1.6%
     within each arm.
6. **First chat −0.5 to +2 points: held.** +1.1. tok/s +5.0%, within noise.
7. **Chats 2–11 all ahead, by 3–15 points: held.** +3.6 to +13.1.

**Controls:**

- **Generated text: held.** Each case's text is byte-identical across all four
  runs (`texts` column). `short-explanation` keeps the hash it has had since
  the fitted-guess runs (`d32db73b…`).
- **New tokens: held.** 5,627 per session in every run.
- **Prefill bytes ±3%: missed.** Prefill bytes rose **+6.2%** per session:
  - the first chat is identical in both arms (7,390 MiB);
  - every later chat reads 4.7–8.7% more in B, and long-synthesis 2,146 MiB
    more.

  The likely mechanism: `runRawCompletion` resets the runner, and so the
  counts, *before* prefill. Under plain LFU, the previous chat's heavily used
  experts keep high counts and stay resident through prefill's tiles. Some of
  those experts are hits for the new prompt. With the counts zeroed, prefill
  evicts them. The prediction assumed prefill ran at about a 0% hit rate
  whatever was resident, which is not quite true. At the phone's ~1.65 GB/s,
  the extra 5.8 GiB per session is about 3–4 s of reads against 3.6 minutes of
  decode saved. Resetting the counts after prefill instead of before is a
  follow-up, not measured here.
- **`cb1-wait` and the head's GPU time:** −4.0 ms and −0.7 ms. That is small,
  in B's favor, and read as GPU-speed noise.

## What it means

The benchmark's single-prompt rows were never affected: each run starts a
fresh process, and there the first chat's +1 point is all aging can add. In
the app, the model stays loaded across conversations. There, today's counts
cost about a fifth of decode speed by the second chat, and they keep costing
it for as long as the app runs. Aging recovers that at no memory cost and with
identical output.

**Default:** on, both platforms, from the commit after this one. The Mac's
evidence is replay only: 16 slots, the same session, 57.6% → 65.0%. The Mac
decode service also keeps one model across conversations.
