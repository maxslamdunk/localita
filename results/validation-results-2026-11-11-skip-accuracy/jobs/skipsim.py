"""The app's expert cache, early read and `miss:<t>` expert skipping, simulated
per sequence on the GPU, for HF transformers' Gemma 4.

What it reproduces, from the Swift runtime at the commit named in
`predictions.md`:

- **The cache** (`PreadExpertStreamer.makeExpertCachePlan`): per layer, `slots`
  slots. A plan takes the requested experts; hits reserve their slots, misses
  go to the unreserved slots in eviction order (empty first, then lowest use
  count, then oldest last use, then lower slot index). Every plan first
  multiplies all use counts by 0.97, then adds 1 to each requested expert.
  Counts start at 0 for each question (`contextDidReset`), and the slots start
  empty (a fresh load, as in the phone benchmark).
- **Prefill** (layer at a time, `PrefillMoEGrouping`): per layer, the distinct
  experts the prompt's tokens route to, in ID order (the installed files keep
  experts in ID order), planned in tiles of 8, each tile avoiding the slots of
  the tile before it. No skipping in prefill.
- **The early read** (`NextLayerExpertPrefetcher`), decode only: at layer L,
  the fitted guess scores layer L+1's experts from L's router input,
  `rmsnorm_no_scale(residual)`, and the best-scoring expert L+1's cache does
  not hold becomes L+1's pending early read (ties to the lower ID). It does
  not change what the cache holds; an early read L+1 then misses is "used".
- **Skipping** (`ExpertSkipPolicy.decide`, kind `miss`): with p the softmax
  over the top-8 logits, a rank-2-or-later expert with p < t that is neither
  resident nor the pending early read is dropped. Its place goes to the most
  used resident expert outside the top 8 (count, then lower ID), at weight 0;
  with no such expert left it is not dropped. The kept weights are divided by
  their sum, then multiplied by the router's per-expert scale. The stand-ins
  are planned like any expert, so they count as hits and gain use count.

`ReferenceSim` is a line-by-line scalar port, for tests. `CacheSim` is the
batched version the evaluation runs; `test_skipsim.py` checks the two agree.
"""
from __future__ import annotations

import struct

import numpy as np
import torch

DECAY = 0.97
TOP_K = 8
TILE = 8


# ---------------------------------------------------------------- guess file

def load_guess(path, num_layers=30, num_experts=128, hidden=2816):
    """The fitted next-layer guess (`NextLayerGuessWeights`, TFNLG1), as an
    fp32 tensor [num_layers, E, D]; row 0 is unused (layer 0 has no guess)."""
    raw = open(path, "rb").read()
    assert raw[:8] == b"TFNLG1\0\0", "not a TFNLG1 file"
    nl, ne, d, gs, first, count = struct.unpack_from("<6I", raw, 8)
    assert (nl, ne, d, first, count) == (num_layers, num_experts, hidden, 1, num_layers - 1), \
        (nl, ne, d, gs, first, count)
    groups = d // gs
    wbytes, gbytes = ne * d, ne * groups * 2
    out = np.zeros((nl, ne, d), dtype=np.float32)

    def bf16(buf):
        u = np.frombuffer(buf, dtype="<u2").astype(np.uint32) << 16
        return u.view(np.float32)

    for t in range(first, first + count):
        start = 64 + (t - first) * (wbytes + 2 * gbytes)
        q = np.frombuffer(raw, dtype=np.uint8, count=wbytes, offset=start).reshape(ne, d)
        s = bf16(raw[start + wbytes:start + wbytes + gbytes]).reshape(ne, groups)
        b = bf16(raw[start + wbytes + gbytes:start + wbytes + 2 * gbytes]).reshape(ne, groups)
        out[t] = (q.astype(np.float32).reshape(ne, groups, gs) * s[:, :, None]
                  + b[:, :, None]).reshape(ne, d)
    return torch.from_numpy(out)


# ------------------------------------------------------- scalar reference

class ReferenceLayer:
    """One layer's `PreadExpertStreamer` cache, LFU with count aging."""

    def __init__(self, slots, num_experts):
        self.slot_expert = [-1] * slots
        self.slot_last = [0] * slots
        self.count = [0.0] * num_experts
        self.clock = 0

    def resident(self):
        return {e for e in self.slot_expert if e >= 0}

    def resident_by_use(self):
        return sorted(self.resident(), key=lambda e: (-self.count[e], e))

    def _evict_key(self, s):
        e = self.slot_expert[s]
        # Empty first; then count, then last use; Swift's sort is stable, so
        # ties keep slot order.
        return (0 if e < 0 else 1, 0.0 if e < 0 else self.count[e],
                0 if e < 0 else self.slot_last[s], s)

    def plan(self, experts, avoid=()):
        """Returns (hit flags, assigned slots)."""
        clock = self.clock + 1
        assigned = [-1] * len(experts)
        reserved = [False] * len(self.slot_expert)
        for i, e in enumerate(experts):
            for s in range(len(self.slot_expert)):
                if not reserved[s] and self.slot_expert[s] == e:
                    assigned[i] = s
                    reserved[s] = True
                    break
        for s in avoid:
            reserved[s] = True
        misses = [i for i in range(len(experts)) if assigned[i] == -1]
        evictable = sorted((s for s in range(len(self.slot_expert)) if not reserved[s]),
                           key=self._evict_key)
        assert len(misses) <= len(evictable)
        self.clock = clock
        self.count = [c * DECAY for c in self.count]
        for e in experts:
            self.count[e] += 1
        for s in assigned:
            if s >= 0:
                self.slot_last[s] = clock
        hits = [a >= 0 for a in assigned]
        for off, i in enumerate(misses):
            s = evictable[off]
            assigned[i] = s
            self.slot_expert[s] = experts[i]
            self.slot_last[s] = clock
        return hits, assigned


def reference_decide(threshold, experts, p, scale, resident, by_use, pending):
    """`ExpertSkipPolicy.decide` for kind `miss` (single step, renormalized).
    p: softmax over the top-8 logits, in rank order. Returns
    (experts, weights, dropped, dropped_mass)."""
    k = len(experts)
    drop = [False] * k
    for i in range(1, k):
        drop[i] = p[i] < threshold and experts[i] not in resident and experts[i] not in pending
    out = list(experts)
    weights = [p[i] * scale[experts[i]] for i in range(k)]
    if not any(drop):
        return out, weights, 0, 0.0
    used = set(experts)
    fillers = [e for e in by_use if e not in used]
    dropped, mass = 0, 0.0
    for i in range(k):
        if not drop[i]:
            continue
        if not fillers:
            drop[i] = False
            continue
        out[i] = fillers.pop(0)
        dropped += 1
        mass += p[i]
    kept = sum(p[i] for i in range(k) if not drop[i])
    weights = [0.0 if drop[i] else p[i] / kept * scale[experts[i]] for i in range(k)]
    return out, weights, dropped, mass


class ReferenceSim:
    """One sequence, all layers: the scalar model the batched one must match."""

    def __init__(self, num_layers, num_experts, slots, threshold):
        self.layers = [ReferenceLayer(slots, num_experts) for _ in range(num_layers)]
        self.pending = [None] * num_layers
        self.threshold = threshold
        self.stats = dict(prefill_reads=0, req=0, hits=0, early_issued=0, early_used=0,
                          dropped=0, dropped_mass=0.0, layer_steps=0)

    def prefill_layer(self, layer, token_experts):
        distinct = sorted({e for row in token_experts for e in row})
        prev = ()
        for t in range(0, len(distinct), TILE):
            hits, assigned = self.layers[layer].plan(distinct[t:t + TILE], avoid=prev)
            self.stats["prefill_reads"] += sum(1 for h in hits if not h)
            prev = tuple(assigned)

    def decode_layer(self, layer, experts, p, scale, guess_scores=None):
        """experts, p: this layer's top 8. guess_scores: layer+1's guess (or None
        on the last layer). Returns (experts, weights)."""
        cache = self.layers[layer]
        pending = {self.pending[layer]} if self.pending[layer] is not None else set()
        out, w, dropped, mass = reference_decide(self.threshold, experts, p, scale,
                                                 cache.resident(), cache.resident_by_use(),
                                                 pending)
        hits, _ = cache.plan(out)
        s = self.stats
        s["req"] += len(out)
        s["hits"] += sum(hits)
        s["early_used"] += sum(1 for e, h in zip(out, hits) if not h and e in pending)
        s["dropped"] += dropped
        s["dropped_mass"] += mass
        s["layer_steps"] += 1
        self.pending[layer] = None
        if guess_scores is not None:
            nxt = self.layers[layer + 1].resident()
            best = None
            for e in range(len(guess_scores)):  # ties to the lower ID
                if e not in nxt and (best is None or guess_scores[e] > guess_scores[best]):
                    best = e
            self.pending[layer + 1] = best
            s["early_issued"] += 1
        return out, w


# ---------------------------------------------------------- batched version

STAT_KEYS = ("prefill_reads", "req", "hits", "early_issued", "early_used", "dropped",
             "dropped_mass", "layer_steps")


class CacheSim:
    """B sequences at once. Rows are independent; `alive` masks rows whose
    generation has ended (their state may change, their stats do not)."""

    def __init__(self, batch, num_layers, num_experts, slots, threshold, device,
                 guess=None):
        self.B, self.NL, self.E, self.S = batch, num_layers, num_experts, slots
        self.threshold = float(threshold)
        self.device = device
        self.guess = guess  # [NL, E, D] fp32 on device, or None (no early read)
        self.slot_expert = torch.full((batch, num_layers, slots), -1, dtype=torch.long, device=device)
        self.slot_last = torch.zeros((batch, num_layers, slots), dtype=torch.long, device=device)
        self.count = torch.zeros((batch, num_layers, num_experts), dtype=torch.float64, device=device)
        self.pending = torch.full((batch, num_layers), -1, dtype=torch.long, device=device)
        self.clock = 0
        self.alive = torch.ones(batch, dtype=torch.bool, device=device)
        self.stats = {k: torch.zeros(batch, dtype=torch.float64, device=device) for k in STAT_KEYS}
        self.slot_index = torch.arange(slots, device=device)
        self.expert_index = torch.arange(num_experts, device=device)
        # When a list: after each decode forward, the running totals [B, len(STAT_KEYS)].
        self.snapshots = None

    @classmethod
    def cat(cls, sims):
        """One sim from several, rows in order (for prefill run in row groups)."""
        out = sims[0]
        for name in ("slot_expert", "slot_last", "count", "pending", "alive"):
            setattr(out, name, torch.cat([getattr(s, name) for s in sims], 0))
        out.stats = {k: torch.cat([s.stats[k] for s in sims], 0) for k in STAT_KEYS}
        out.clock = max(s.clock for s in sims)
        out.B = sum(s.B for s in sims)
        return out

    def select(self, rows):
        """Keep only `rows` (a LongTensor of row indices), in that order."""
        for name in ("slot_expert", "slot_last", "count", "pending", "alive"):
            setattr(self, name, getattr(self, name).index_select(0, rows))
        self.stats = {k: v.index_select(0, rows) for k, v in self.stats.items()}
        self.B = len(rows)

    def _resident(self, layer):
        """[B, E] bool: experts the layer's cache holds."""
        se = self.slot_expert[:, layer]
        res = torch.zeros((self.B, self.E + 1), dtype=torch.bool, device=self.device)
        res.scatter_(1, torch.where(se < 0, self.E, se), True)
        return res[:, :self.E]

    def _plan(self, layer, experts, valid, active, avoid=None):
        """experts [B, K] (distinct per row where valid), valid [B, K] bool,
        active [B] bool, avoid [B, S] bool or None. Returns (hit [B, K],
        assigned slot [B, K])."""
        B, S = self.B, self.S
        se = self.slot_expert[:, layer]          # [B, S]
        last = self.slot_last[:, layer]
        cnt = self.count[:, layer]                # [B, E]
        clock = self.clock + 1
        valid = valid & active[:, None]

        match = (se[:, :, None] == experts[:, None, :]) & valid[:, None, :] & (se[:, :, None] >= 0)
        hit = match.any(1)                                           # [B, K]
        hit_slot = torch.where(hit, match.float().argmax(1), -1)     # [B, K]
        reserved = match.any(2)                                      # [B, S]
        if avoid is not None:
            reserved = reserved | avoid

        # Eviction order: unreserved first, empty first, count, last use, slot.
        empty = se < 0
        slot_count = torch.where(empty, 0.0, cnt.gather(1, se.clamp(min=0)))
        order = self.slot_index.expand(B, S).clone()
        for key in (torch.where(empty, 0, last), slot_count, (~empty).long(), reserved.long()):
            k = key.gather(1, order)
            _, idx = torch.sort(k, dim=1, stable=True)
            order = order.gather(1, idx)

        miss = valid & ~hit
        rank = miss.long().cumsum(1) - 1
        target = order.gather(1, rank.clamp(min=0))                  # [B, K]
        assigned = torch.where(hit, hit_slot, torch.where(miss, target, -1))

        # Updates, for active rows only.
        a3 = active[:, None]
        new_cnt = torch.where(a3, cnt * DECAY, cnt)
        add = torch.zeros((B, self.E + 1), dtype=new_cnt.dtype, device=self.device)
        add.scatter_add_(1, torch.where(valid, experts, self.E), valid.to(new_cnt.dtype))
        self.count[:, layer] = new_cnt + add[:, :self.E]

        upd = torch.zeros((B, S + 1), dtype=torch.bool, device=self.device)
        upd.scatter_(1, torch.where(assigned >= 0, assigned, S), True)
        upd = upd[:, :S]
        self.slot_last[:, layer] = torch.where(upd, clock, last)
        new_se = se.clone()
        src = torch.where(miss, assigned, S)
        tmp = torch.cat([new_se, torch.zeros((B, 1), dtype=new_se.dtype, device=self.device)], 1)
        tmp.scatter_(1, src, torch.where(miss, experts, 0))
        self.slot_expert[:, layer] = tmp[:, :S]
        self.clock = clock
        return hit & valid, assigned

    def prefill_layer(self, layer, token_experts, token_valid):
        """token_experts [B, T, 8], token_valid [B, T] bool (False for padding)."""
        B = self.B
        used = torch.zeros((B, self.E + 1), dtype=torch.bool, device=self.device)
        flat = torch.where(token_valid[:, :, None], token_experts, self.E).reshape(B, -1)
        used.scatter_(1, flat, True)
        used = used[:, :self.E]
        n = used.sum(1)
        key = torch.where(used, self.expert_index, self.E + self.expert_index)
        distinct = torch.sort(key, dim=1).values                    # used experts first, ascending
        prev = None
        for t in range(0, int(n.max()), TILE):
            ex = distinct[:, t:t + TILE]
            valid = (t + torch.arange(ex.shape[1], device=self.device))[None, :] < n[:, None]
            ex = torch.where(valid, ex, 0)
            active = n > t
            hit, assigned = self._plan(layer, ex, valid, active, avoid=prev)
            self.stats["prefill_reads"] += torch.where(self.alive, (valid & ~hit).sum(1), 0).double()
            prev = torch.zeros((B, self.S + 1), dtype=torch.bool, device=self.device)
            prev.scatter_(1, torch.where(assigned >= 0, assigned, self.S), True)
            prev = prev[:, :self.S] & active[:, None]

    def decode_layer(self, layer, experts, p, scale, router_input=None):
        """experts [B, 8] rank order, p [B, 8] softmax over the top-8 logits,
        scale [E] per-expert scale, router_input [B, D] =
        rmsnorm_no_scale(residual) for the guess. Returns (experts, weights)."""
        B = self.B
        alive = self.alive
        res = self._resident(layer)
        pend = self.pending[:, layer]
        is_pend = experts == pend[:, None]
        fg = ~res.gather(1, experts) & ~is_pend
        drop = (p < self.threshold) & fg
        drop[:, 0] = False

        # Stand-ins: resident, outside the top 8, most used first, then lower ID.
        in_top = torch.zeros((B, self.E), dtype=torch.bool, device=self.device)
        in_top.scatter_(1, experts, True)
        cand = res & ~in_top
        neg = torch.where(cand, -self.count[:, layer], float("inf"))
        _, by_use = torch.sort(neg, dim=1, stable=True)              # ids ascending within ties
        n_fill = cand.sum(1)
        j = drop.long().cumsum(1) - 1
        drop = drop & (j < n_fill[:, None])
        filler = by_use.gather(1, j.clamp(min=0))
        out = torch.where(drop, filler, experts)

        kept = torch.where(drop, 0.0, p).sum(1, keepdim=True)
        w = torch.where(drop, 0.0, p / kept) * scale[experts].to(p.dtype)

        hit, _ = self._plan(layer, out, torch.ones_like(drop), torch.ones_like(alive))
        miss = ~hit
        early_used = (miss & (out == pend[:, None])).sum(1)
        st = self.stats
        a = alive.double()
        st["req"] += a * out.shape[1]
        st["hits"] += a * hit.sum(1)
        st["early_used"] += a * early_used
        st["dropped"] += a * drop.sum(1)
        st["dropped_mass"] += a * torch.where(drop, p, 0.0).sum(1).double()
        st["layer_steps"] += a
        self.pending[:, layer] = -1
        # Rows where anything was dropped; the others keep the router's own weights.
        self.last_changed = drop.any(1)

        if self.guess is not None and router_input is not None and layer + 1 < self.NL:
            scores = router_input.float() @ self.guess[layer + 1].T  # [B, E]
            scores = torch.where(self._resident(layer + 1), float("-inf"), scores)
            self.pending[:, layer + 1] = scores.argmax(1)            # first maximum
            st["early_issued"] += a
        if layer == self.NL - 1 and self.snapshots is not None:
            self.snapshots.append(torch.stack([st[k] for k in STAT_KEYS], 1).clone())
        return out, w

    def row_stats(self):
        return {k: v.cpu().tolist() for k, v in self.stats.items()}


# ------------------------------------------------------------- HF wiring

class SimRouter(torch.nn.Module):
    """Wraps one layer's `Gemma4TextRouter`. Outside a sim (`state.sim` None)
    it is the router unchanged."""

    def __init__(self, router, layer, state):
        super().__init__()
        self.router = router
        self.layer = layer
        self.state = state

    def forward(self, hidden_states):
        probs, weights, index = self.router(hidden_states)
        sim = self.state.sim
        if sim is None:
            return probs, weights, index
        B = sim.B
        T = hidden_states.shape[0] // B
        assert T * B == hidden_states.shape[0], "rows do not match the sim's batch"
        if T > 1:  # a prompt: prefill
            valid = self.state.token_valid
            if valid is None or valid.shape[1] != T:
                valid = torch.ones((B, T), dtype=torch.bool, device=index.device)
            sim.prefill_layer(self.layer, index.view(B, T, -1), valid)
            return probs, weights, index
        p = probs.gather(1, index)
        p = p / p.sum(1, keepdim=True)
        router_input = self.router.norm(hidden_states) if sim.guess is not None else None
        out, w = sim.decode_layer(self.layer, index, p, self.router.per_expert_scale, router_input)
        # Where nothing was dropped, keep HF's weights bit for bit: recomputing
        # them can move the last bit, enough to flip a greedy near-tie.
        w = torch.where(sim.last_changed[:, None], w.to(weights.dtype), weights)
        return probs, w, out


class SimState:
    """`sim`: the CacheSim in use, or None. `token_valid`: [B, T] bool for the
    next prompt (False on left padding), or None for all valid."""

    def __init__(self):
        self.sim = None
        self.token_valid = None


class ChunkedExperts(torch.nn.Module):
    """Runs a layer's experts over at most `chunk` tokens at a time. Each
    token's expert output depends on that token alone, so this changes memory,
    not results; a whole batch's prefill otherwise needs tens of GB at once."""

    def __init__(self, experts, chunk=8192):
        super().__init__()
        self.experts = experts
        self.chunk = chunk

    def forward(self, hidden_states, top_k_index, top_k_weights):
        n = hidden_states.shape[0]
        if n <= self.chunk:
            return self.experts(hidden_states, top_k_index, top_k_weights)
        return torch.cat([self.experts(hidden_states[i:i + self.chunk], top_k_index[i:i + self.chunk],
                                       top_k_weights[i:i + self.chunk])
                          for i in range(0, n, self.chunk)])


def chunk_sdpa_by_rows(rows=8):
    """Makes HF's "sdpa" attention run a multi-token query (a prompt) over at
    most `rows` sequences at a time. Rows attend only to themselves, so the
    output is the same; the memory for 64 long prompts at once is not."""
    from transformers import AttentionInterface
    from transformers.integrations.sdpa_attention import sdpa_attention_forward

    def forward(module, query, key, value, attention_mask, **kwargs):
        B = query.shape[0]
        if query.shape[2] == 1 or B <= rows:
            return sdpa_attention_forward(module, query, key, value, attention_mask, **kwargs)
        outs = []
        for i in range(0, B, rows):
            mask = attention_mask
            if mask is not None and mask.shape[0] == B:
                mask = mask[i:i + rows]
            out, _ = sdpa_attention_forward(module, query[i:i + rows], key[i:i + rows],
                                            value[i:i + rows], mask, **kwargs)
            outs.append(out)
        return torch.cat(outs, 0), None

    AttentionInterface.register("sdpa", forward)


def compact_cache(cache):
    """A sliding-window layer keeps its last tokens as a view of the whole
    prompt's K/V, which keeps all of it allocated. Copy views out."""
    for layer in cache.layers:
        for name in ("keys", "values"):
            t = getattr(layer, name, None)
            if t is not None and t.untyped_storage().nbytes() > t.numel() * t.element_size():
                setattr(layer, name, t.clone())
    return cache


def merge_caches(caches):
    """One HF DynamicCache from several of equal length, rows in order, a
    layer at a time so that only one layer is ever held twice."""
    base = caches[0]
    for i, layer in enumerate(base.layers):
        layer.keys = torch.cat([c.layers[i].keys for c in caches], 0)
        layer.values = torch.cat([c.layers[i].values for c in caches], 0)
        for c in caches[1:]:
            c.layers[i].keys = c.layers[i].values = None
    return base


def install(model):
    """Wraps every decoder layer's router, and its experts in token chunks,
    and chunks prompt attention by rows; returns the shared state."""
    chunk_sdpa_by_rows()
    state = SimState()
    layers = None
    for name, module in model.named_modules():
        if name.endswith("language_model.layers") or name.endswith("model.layers"):
            layers = module
            break
    assert layers is not None, "decoder layers not found"
    for i, layer in enumerate(layers):
        layer.router = SimRouter(layer.router, i, state)
        layer.experts = ChunkedExperts(layer.experts)
    return state
