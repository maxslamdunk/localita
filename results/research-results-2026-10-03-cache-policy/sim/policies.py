"""Cache policies for sim.replay. Each is built per layer by a factory called as
factory(slots=, layer=, trace=); `trace` is only for policies that peek at the
future (Belady) or need the layer's scores."""
from collections import OrderedDict
import numpy as np

INF = 1 << 40


class _Scored:
    """Base: evict the cached, unchosen experts with the lowest `key`."""

    def __init__(self, slots, **_):
        self.slots = slots
        self.resident = set()

    def key(self, e, t):
        raise NotImplementedError

    def touch(self, t, chosen):
        pass

    def access(self, t, chosen):
        misses = [e for e in chosen if e not in self.resident]
        need = len(self.resident) + len(misses) - self.slots
        if need > 0:
            cand = sorted((e for e in self.resident if e not in chosen),
                          key=lambda e: self.key(e, t))
            for v in cand[:need]:
                self.resident.remove(v)
        self.touch(t, chosen)
        self.resident.update(misses)
        return misses


class LFU(_Scored):
    """The runtime's policy (`shouldEvictSlot`): lowest use count, ties to the
    least recently used; counts never reset."""

    def __init__(self, slots, trace=None, **_):
        super().__init__(slots)
        E = trace.E if trace is not None else 128
        self.count = np.zeros(E, np.int64)
        self.last = np.zeros(E, np.int64)

    def key(self, e, t):
        return (self.count[e], self.last[e])

    def touch(self, t, chosen):
        self.count[chosen] += 1
        self.last[chosen] = t + 1


class LRU(LFU):
    def key(self, e, t):
        return self.last[e]


class DecayLFU(LFU):
    """Frequency with exponential forgetting (LRFU/CRF): each use adds 1 and
    every token multiplies all counts by `decay`. decay=1 is LFU, small
    decay tends to LRU. Stored as count * decay^-t to stay O(1) per use;
    float64 holds that for the trace lengths used here."""

    def __init__(self, slots, decay, **kw):
        super().__init__(slots, **kw)
        self.crf = np.zeros_like(self.count, dtype=np.float64)
        self.logd = np.log(decay)

    def key(self, e, t):
        return (self.crf[e], self.last[e])

    def touch(self, t, chosen):
        super().touch(t, chosen)
        self.crf[chosen] += np.exp(-self.logd * t)


def decay_lfu(decay):
    return lambda **kw: DecayLFU(decay=decay, **kw)


class Belady(_Scored):
    """Offline optimum (MIN): evict the expert whose next use is furthest."""

    def __init__(self, slots, layer, trace, **_):
        super().__init__(slots)
        ex = trace.experts[:, layer]
        T = ex.shape[0]
        self.next = np.full((T, trace.E), INF, np.int64)
        nu = np.full(trace.E, INF, np.int64)
        for t in range(T - 1, -1, -1):
            self.next[t] = nu
            nu[ex[t]] = t

    def key(self, e, t):
        return -self.next[t, e]


class ARC:
    """Adaptive Replacement Cache (Megiddo & Modha) with the chosen experts
    pinned: T1 seen once recently, T2 seen at least twice, B1/B2 their ghosts,
    p the adaptive target size of T1."""

    def __init__(self, slots, **_):
        self.c = slots
        self.p = 0.0
        self.t1, self.t2, self.b1, self.b2 = (OrderedDict() for _ in range(4))

    @property
    def resident(self):
        return self.t1.keys() | self.t2.keys()

    def _evict_from(self, lst, ghost, pinned):
        for e in lst:
            if e not in pinned:
                del lst[e]
                ghost[e] = None
                return True
        return False

    def _replace(self, x, pinned):
        if len(self.t1) + len(self.t2) < self.c:
            return
        prefer_t1 = len(self.t1) > 0 and (len(self.t1) > self.p or (x in self.b2 and len(self.t1) == int(self.p)))
        first, second = ((self.t1, self.b1), (self.t2, self.b2)) if prefer_t1 else ((self.t2, self.b2), (self.t1, self.b1))
        if not self._evict_from(*first, pinned):
            assert self._evict_from(*second, pinned)

    def access(self, t, chosen):
        pinned = set(chosen)
        misses = []
        for x in chosen:
            if x in self.t1:
                del self.t1[x]; self.t2[x] = None
            elif x in self.t2:
                self.t2.move_to_end(x)
        for x in chosen:
            if x in self.t1 or x in self.t2:
                continue
            misses.append(x)
            if x in self.b1:
                self.p = min(self.c, self.p + max(len(self.b2) / len(self.b1), 1))
                self._replace(x, pinned)
                del self.b1[x]; self.t2[x] = None
            elif x in self.b2:
                self.p = max(0.0, self.p - max(len(self.b1) / len(self.b2), 1))
                self._replace(x, pinned)
                del self.b2[x]; self.t2[x] = None
            else:
                l1 = len(self.t1) + len(self.b1)
                total = l1 + len(self.t2) + len(self.b2)
                if l1 >= self.c:
                    if len(self.t1) < self.c:
                        self.b1.popitem(last=False)
                        self._replace(x, pinned)
                    elif not self._evict_from(self.t1, {}, pinned):  # no ghost kept
                        self._replace(x, pinned)
                elif total >= self.c:
                    if total >= 2 * self.c and self.b2:
                        self.b2.popitem(last=False)
                    self._replace(x, pinned)
                self.t1[x] = None
        assert len(self.t1) + len(self.t2) <= self.c
        return misses


POLICIES = {
    "lfu": LFU,
    "lru": LRU,
    "arc": ARC,
    "decay0.99": decay_lfu(0.99),
    "decay0.995": decay_lfu(0.995),
    "decay0.998": decay_lfu(0.998),
    "decay0.999": decay_lfu(0.999),
    "belady": Belady,
}
