"""Checks the simulation against the Swift runtime's rules.

    python3 test_skipsim.py [path to the bundled guess .bin]

1. The `miss` cases of `ExpertSkipPolicyTests.swift`, through both the scalar
   port and the batched sim.
2. Random traces (prefill, then decode with skipping and early reads) through
   both, row by row: identical experts, cache contents, counts and stats, and
   weights within float tolerance. Eviction and stand-in ties come up often,
   since use counts tie whenever two experts share a history.
3. With the guess file given: its header and size parse, and every matrix is
   finite.
"""
import math
import random
import sys

import torch

from skipsim import CacheSim, ReferenceSim, STAT_KEYS, TOP_K, load_guess, reference_decide


def softmax(z):
    m = max(z)
    e = [math.exp(x - m) for x in z]
    s = sum(e)
    return [x / s for x in e]


# Swift: ExpertSkipPolicyTests.logits()
Z = [-10.0] * 16
for i, v in enumerate([2.0, 1.8, 1.6, 1.4, 1.2, 1.0, -0.5, -0.6]):
    Z[i] = v
Z[8], Z[9] = 0.5, 0.4
P = softmax(Z[:8])
ONES = [1.0] * 16


def batched_case(resident_by_use, pending, threshold=0.08):
    """Runs one decide through CacheSim: resident experts placed in slots,
    counts set so that `resident_by_use` is most used first."""
    sim = CacheSim(1, 1, 16, 24, threshold, "cpu")
    for s, e in enumerate(resident_by_use):
        sim.slot_expert[0, 0, s] = e
        sim.count[0, 0, e] = 10.0 - s
    if pending is not None:
        sim.pending[0, 0] = pending
    out, w = sim.decode_layer(0, torch.arange(8)[None], torch.tensor([P], dtype=torch.float32),
                              torch.ones(16))
    return out[0].tolist(), w[0].tolist(), sim.stats


def test_swift_cases():
    # missDropsOnlyLowWeightForegroundMisses
    assert P[6] < 0.08 and P[7] < 0.08 and P[5] >= 0.08
    out, w, dropped, mass = reference_decide(0.08, list(range(8)), P, ONES, {7, 12, 13},
                                             [13, 12, 7], set())
    assert dropped == 1 and out == [0, 1, 2, 3, 4, 5, 13, 7] and w[6] == 0
    assert abs(sum(w) - 1) < 1e-3 and abs(mass - P[6]) < 1e-9
    bout, bw, st = batched_case([13, 12, 7], None)
    assert bout == out and bw[6] == 0 and abs(sum(bw) - 1) < 1e-3
    assert st["dropped"].item() == 1 and abs(st["dropped_mass"].item() - P[6]) < 1e-6

    # A pending early read is not a foreground miss (Swift tests this with
    # missrank:7; here with miss:0.08): 6 is pending, so only 7 drops.
    out, w, dropped, _ = reference_decide(0.08, list(range(8)), P, ONES, {12, 13}, [12, 13], {6})
    assert out == [0, 1, 2, 3, 4, 5, 6, 12] and dropped == 1
    bout, _, _ = batched_case([12, 13], 6)
    assert bout == out

    # noStandInMeansNoDrop, for miss
    out, w, dropped, _ = reference_decide(0.08, list(range(8)), P, ONES, set(), [], set())
    assert dropped == 0 and out == list(range(8))
    bout, _, st = batched_case([], None)
    assert bout == list(range(8)) and st["dropped"].item() == 0

    # One stand-in for two drops: the first drop takes it, the second stays.
    out, _, dropped, _ = reference_decide(0.08, list(range(8)), P, ONES, {12}, [12], set())
    assert out == [0, 1, 2, 3, 4, 5, 12, 7] and dropped == 1
    bout, _, _ = batched_case([12], None)
    assert bout == out
    print("swift cases: ok")


def random_trace(seed, rows=6, layers=4, experts=40, slots=16, steps=60, threshold=0.10):
    rng = random.Random(seed)
    torch.manual_seed(seed)
    dim = 12
    guess = torch.randn(layers, experts, dim)
    scale = torch.rand(experts) + 0.5
    refs = [ReferenceSim(layers, experts, slots, threshold) for _ in range(rows)]
    sim = CacheSim(rows, layers, experts, slots, threshold, "cpu", guess=guess)
    # A skewed popularity per layer, so that hits, ties and drops all happen.
    pop = [[rng.random() ** 3 for _ in range(experts)] for _ in range(layers)]

    def route(layer):
        logits = []
        for _ in range(rows):
            logits.append([math.log(pop[layer][e] + 1e-3) + rng.gauss(0, 1.5) for e in range(experts)])
        z = torch.tensor(logits, dtype=torch.float32)
        top = torch.topk(z, TOP_K, dim=1)
        p = torch.softmax(top.values, dim=1)
        return top.indices, p

    # Prefill: different prompt lengths, left padding.
    T = 9
    lengths = [rng.randint(2, T) for _ in range(rows)]
    valid = torch.tensor([[t >= T - n for t in range(T)] for n in lengths])
    for layer in range(layers):
        idx = torch.stack([route(layer)[0] for _ in range(T)], 1)  # [rows, T, 8]
        sim.prefill_layer(layer, idx, valid)
        for r in range(rows):
            toks = [idx[r, t].tolist() for t in range(T) if valid[r, t]]
            refs[r].prefill_layer(layer, toks)

    for _ in range(steps):
        for layer in range(layers):
            idx, p = route(layer)
            x = torch.randn(rows, dim)
            out, w = sim.decode_layer(layer, idx, p, scale, x)
            scores = (x @ guess[layer + 1].T) if layer + 1 < layers else None
            for r in range(rows):
                rout, rw = refs[r].decode_layer(
                    layer, idx[r].tolist(), [float(v) for v in p[r]], scale.tolist(),
                    scores[r].tolist() if scores is not None else None)
                assert out[r].tolist() == rout, (seed, layer, r, out[r].tolist(), rout)
                assert all(abs(a - b) < 1e-5 for a, b in zip(w[r].tolist(), rw)), (w[r], rw)

    for r in range(rows):
        for layer in range(layers):
            ref = refs[r].layers[layer]
            assert sim.slot_expert[r, layer].tolist() == ref.slot_expert, (seed, r, layer)
            assert all(abs(a - b) < 1e-9 for a, b in zip(sim.count[r, layer].tolist(), ref.count))
        for k in STAT_KEYS:
            a, b = sim.stats[k][r].item(), refs[r].stats[k]
            assert abs(a - b) < 1e-6, (seed, r, k, a, b)
    return {k: sum(ref.stats[k] for ref in refs) for k in STAT_KEYS}


def test_random_traces():
    total = None
    for seed in range(40):
        s = random_trace(seed, threshold=[0.0, 0.08, 0.10, 0.3][seed % 4])
        total = s if total is None else {k: total[k] + s[k] for k in s}
    assert total["dropped"] > 100 and total["early_used"] > 100 and total["hits"] > 1000, total
    print("random traces: ok,", {k: round(v) for k, v in total.items()})


def test_select():
    sim = CacheSim(3, 2, 20, 16, 0.1, "cpu")
    sim.count[1, 0, 5] = 3.0
    sim.select(torch.tensor([2, 1]))
    assert sim.B == 2 and sim.count[1, 0, 5] == 3.0 and sim.stats["req"].shape == (2,)
    print("select: ok")


if __name__ == "__main__":
    test_swift_cases()
    test_random_traces()
    test_select()
    if len(sys.argv) > 1:
        g = load_guess(sys.argv[1])
        assert g.shape == (30, 128, 2816) and torch.isfinite(g).all() and g[0].abs().sum() == 0
        print("guess: ok, |w| mean", g[1:].abs().mean().item())
