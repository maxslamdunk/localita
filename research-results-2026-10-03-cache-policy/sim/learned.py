"""Learned eviction: predict each cached expert's time to next use from its
access history and the current router scores, evict the one predicted furthest.
Labels come from the trace's future (what Belady knows); features only from
the past and the current token, so the policy is causal.

A ridge regression on a handful of features: cheap enough to run in the
runtime's planner (a dot product per candidate, a few candidates per miss).
"""
import json
import numpy as np

import sim
from policies import LFU, _Scored

DECAYS = (0.9, 0.98, 0.995)
LABEL_CAP = 256


class History:
    """Per-layer access statistics, updated after each token's access."""

    def __init__(self, E):
        self.count = np.zeros(E)
        self.last = np.full(E, -1.0)
        self.crf = np.zeros((len(DECAYS), E))
        self.gap = np.zeros(E)          # EMA of the gap between uses
        self.recent = np.zeros(E)        # uses in the last 8 tokens
        self.window = []

    def update(self, t, chosen):
        c = np.asarray(chosen)
        for i, d in enumerate(DECAYS):
            self.crf[i] *= d
            self.crf[i, c] += 1
        seen = self.last[c] >= 0
        g = t - self.last[c]
        self.gap[c] = np.where(seen, np.where(self.gap[c] > 0, 0.7 * self.gap[c] + 0.3 * g, g), 0)
        self.count[c] += 1
        self.last[c] = t
        self.window.append(c)
        self.recent[c] += 1
        if len(self.window) > 8:
            self.recent[self.window.pop(0)] -= 1

    def features(self, t, experts, scores_t, layer, L):
        """Rows for `experts` at token t, before t's access. `scores_t` is the
        router's scores over all experts for this token and layer."""
        e = np.asarray(experts)
        s = scores_t.astype(np.float32)
        z = (s - s.mean()) / (s.std() + 1e-6)
        rank = np.empty(len(s)); rank[np.argsort(-s)] = np.arange(len(s))
        age = np.where(self.last[e] >= 0, t - self.last[e], t + 1)
        gap = np.where(self.gap[e] > 0, self.gap[e], age)
        cols = [
            np.ones(len(e)),
            np.log1p(self.count[e]),
            np.log1p(self.count[e] / (t + 1) * 128),   # share of this layer's uses
            np.log1p(age),
            np.log1p(gap),
            np.log1p(self.recent[e]),
            *[np.log1p(self.crf[i, e]) for i in range(len(DECAYS))],
            z[e],
            np.log1p(rank[e]),
            np.full(len(e), layer / L),
        ]
        return np.stack(cols, axis=1)


NAMES = ["bias", "log count", "log share", "log age", "log gap", "log recent8",
         *["log crf%.3g" % d for d in DECAYS], "score z", "log rank", "layer"]


def samples(trace, slots, every=1):
    """(X, y) at each eviction-relevant point: the LFU-resident, unchosen
    experts of every layer at every `every`-th token, labelled with
    log(time to next use), capped; censored ones near the end are dropped."""
    X, Y, G = [], [], []
    T, L = trace.T, trace.L
    for l in range(L):
        ex = trace.experts[:, l]
        nxt = np.full((T, trace.E), 1 << 40, np.int64)
        nu = np.full(trace.E, 1 << 40, np.int64)
        for t in range(T - 1, -1, -1):
            nxt[t] = nu
            nu[ex[t]] = t
        h, lfu = History(trace.E), LFU(slots, trace=trace)
        for t in range(T):
            chosen = [int(e) for e in ex[t]]
            if t >= sim.WARMUP and t % every == 0:
                cand = [e for e in lfu.resident if e not in chosen]
                if cand:
                    d = nxt[t, cand] - t
                    keep = (d <= LABEL_CAP) | (t + LABEL_CAP < T)
                    cand = [c for c, k in zip(cand, keep) if k]
                    if cand:
                        X.append(h.features(t, cand, trace.scores[t, l], l, L))
                        Y.append(np.log(np.minimum(nxt[t, cand] - t, LABEL_CAP)))
                        G.append(np.full(len(cand), len(G)))
            lfu.access(t, chosen)
            h.update(t, chosen)
    return np.concatenate(X), np.concatenate(Y), np.concatenate(G)


def expand(X):
    """Quadratic features: the linear ones plus all pairwise products of the
    history and score features (not the bias or the layer)."""
    core = X[:, 1:-1]
    i, j = np.triu_indices(core.shape[1])
    return np.concatenate([X, core[:, i] * core[:, j]], axis=1)


def fit(X, y, lam):
    mu, sd = X.mean(0), X.std(0)
    mu[0], sd[0] = 0, 1
    sd[sd == 0] = 1
    Z = (X - mu) / sd
    w = np.linalg.solve(Z.T @ Z + lam * np.eye(Z.shape[1]) * len(Z) / 1000, Z.T @ y)
    return {"w": w.tolist(), "mu": mu.tolist(), "sd": sd.tolist(), "lam": lam, "names": NAMES}


def fit_rank(X, y, g, lam, pairs_per_group=12, seed=0):
    """Pairwise ranking: logistic regression on x_i - x_j predicting that i's
    next use comes later than j's, over random pairs within each eviction
    decision. Only the order matters to eviction, not the distance."""
    rng = np.random.default_rng(seed)
    mu, sd = X.mean(0), X.std(0)
    mu[0], sd[0] = 0, 1
    sd[sd == 0] = 1
    Z = (X - mu) / sd
    starts = np.flatnonzero(np.r_[True, g[1:] != g[:-1]])
    sizes = np.diff(np.r_[starts, len(g)])
    keep = sizes >= 2
    starts, sizes = starts[keep], sizes[keep]
    a = starts.repeat(pairs_per_group) + (rng.random(len(starts) * pairs_per_group) * sizes.repeat(pairs_per_group)).astype(int)
    b = starts.repeat(pairs_per_group) + (rng.random(len(starts) * pairs_per_group) * sizes.repeat(pairs_per_group)).astype(int)
    ok = y[a] != y[b]
    a, b = a[ok], b[ok]
    D = (Z[a] - Z[b])[:, 1:]                     # the bias cancels
    t = (y[a] > y[b]).astype(float)
    w = np.zeros(D.shape[1])
    for _ in range(25):                          # Newton / IRLS
        p = 1 / (1 + np.exp(-(D @ w)))
        H = (D * (p * (1 - p))[:, None]).T @ D + lam * len(D) / 1000 * np.eye(len(w))
        step = np.linalg.solve(H, D.T @ (t - p) - lam * len(D) / 1000 * w)
        w += step
        if np.abs(step).max() < 1e-6:
            break
    return {"w": [0.0] + w.tolist(), "mu": mu.tolist(), "sd": sd.tolist(), "lam": lam,
            "names": NAMES, "objective": "rank", "pairs": int(len(D))}


class Learned(_Scored):
    def __init__(self, slots, layer, trace, model, **_):
        super().__init__(slots)
        self.layer, self.trace = layer, trace
        self.h = History(trace.E)
        self.quad = model.get("quadratic", False)
        self.w = np.asarray(model["w"]) / np.asarray(model["sd"])
        self.b = -float(np.dot(np.asarray(model["mu"]), self.w))
        self.pred = {}

    def access(self, t, chosen):
        misses = [e for e in chosen if e not in self.resident]
        need = len(self.resident) + len(misses) - self.slots
        if need > 0:
            cand = [e for e in self.resident if e not in chosen]
            F = self.h.features(t, cand, self.trace.scores[t, self.layer], self.layer, self.trace.L)
            if self.quad:
                F = expand(F)
            p = F @ self.w + self.b                  # predicted log time to next use
            for i in np.argsort(-p, kind="stable")[:need]:
                self.resident.remove(cand[i])
        self.h.update(t, chosen)
        self.resident.update(misses)
        return misses


def learned(model):
    return lambda **kw: Learned(model=model, **kw)


def save(model, path):
    json.dump(model, open(path, "w"), indent=1)


def load(path):
    return json.load(open(path))
