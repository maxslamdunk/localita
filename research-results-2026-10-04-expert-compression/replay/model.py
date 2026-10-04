#!/usr/bin/env python3
"""What a compressed expert format would do to the phone's `io`: arithmetic.

Per layer-step with n foreground reads (from schedule.py at 24 slots, count
aging, fitted early read), storage serial, read time a + bytes / B:

  raw:              n (a + S/B)
  comp, whole:      n (a + r S/B) + S_out / R_all
                    (each expert decodes while the next one reads; the last
                    expert's decode, spread over every core, is exposed)
  comp, split last: n (a + r S/B) + a + max(0, D_big - (a + r c/B)) + c_out / R_one
                    (the last expert as [all but one chunk, one chunk])
  side only:        n (a + r_side S/B) + side decode of the last expert (3 tasks)

Early reads happen in the GPU gap and are left out (their decode fits there
too); that leaves out a small gain from shorter early reads.

    model.py schedule-*.txt
"""
import sys
from collections import Counter

S = 3_358_720          # expert bytes, raw
R = 0.8602             # compressed / raw, 4 KiB-aligned (excodec, 1,920 held-out experts)
R_SIDE = 0.9258        # side-only record / raw, 4 KiB-aligned (replay side-bench, 256 experts)
SIDE_M1_US = 212.0     # side decode of one expert, one M1 P-core thread; runs as 3 tasks
CHUNK_OUT = 139_392    # bytes out per chunk
P50_READ_MS = 2.142    # iPhone 17 ioread p50 at S, QD1 (MEASUREMENTS.md 2026-09-16)
M1_P_CORE = 1.97e9     # excodec decode, one M1 performance core, output bytes/s


def per_layer(n, a_ms, p_core, agg_factor):
    B = S / ((P50_READ_MS - a_ms) / 1e3)          # bytes/s, so that a + S/B = p50
    a = a_ms / 1e3
    r_all = p_core * agg_factor
    raw = n * (a + S / B)
    side = n * (a + R_SIDE * S / B) + SIDE_M1_US / 1e6 / 3 * (M1_P_CORE / p_core) if n else raw
    if n == 0:
        return raw, raw, raw, raw
    reads = n * (a + R * S / B)
    whole = reads + S / r_all
    big_out = S - CHUNK_OUT
    d_big = big_out / r_all
    small_read = a + R * CHUNK_OUT / B
    split = reads + a + max(0.0, d_big - small_read) + CHUNK_OUT / p_core
    return raw, whole, split, side


def main():
    for path in sys.argv[1:]:
        hist = Counter()
        tokens = set()
        for line in open(path):
            f = line.split()
            tokens.add(int(f[0]))
            hist[int(f[3])] += 1
        T = len(tokens)
        fg = sum(k * v for k, v in hist.items()) / T
        print(f"\n{path}: {T} tokens, {fg:.1f} foreground reads/token; layer-steps by reads: "
              + ", ".join(f"{k}:{v / sum(hist.values()):.0%}" for k, v in sorted(hist.items())))
        print("  a (ms)  A19 P-core  all-core   raw io   whole: d io     split last: d io    side only: d io  (ms/token)")
        for a_ms in (0.05, 0.1, 0.2):
            for speed, agg in ((1.0, 3.4), (1.5, 3.4)):
                p = M1_P_CORE * speed
                tot = [0.0, 0.0, 0.0, 0.0]
                for n, cnt in hist.items():
                    for i, v in enumerate(per_layer(n, a_ms, p, agg)):
                        tot[i] += v * cnt
                raw, whole, split, side = (x / T * 1e3 for x in tot)
                print(f"  {a_ms:5.2f}   {p / 1e9:5.2f} GB/s  {p * agg / 1e9:5.1f} GB/s  {raw:6.1f}   "
                      f"{whole - raw:+6.1f} ({(whole / raw - 1):+5.1%})   {split - raw:+6.1f} ({(split / raw - 1):+5.1%})   "
                      f"{side - raw:+6.1f} ({(side / raw - 1):+5.1%})")


if __name__ == "__main__":
    main()
