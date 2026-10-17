"""P1, first half: the exported router reproduces the logged scores and top-8."""
import sys
import numpy as np
import trace as tr

d = sys.argv[1]
meta, data = tr.load(d)
L_count, K = meta["numLayers"], meta["topK"]
print("records", len(data), "tokens", len(data) / L_count)
assert len(data) % L_count == 0
layers = data["layer"].reshape(-1, L_count)
assert (layers == np.arange(L_count)).all(), "records not in layer order"
max_abs, same_top, n = 0.0, 0, 0
for L in range(L_count):
    W = tr.router(d, L, meta)
    sel = data[data["layer"] == L]
    x = sel["router_input"].astype(np.float32)
    s = x @ W.T
    max_abs = max(max_abs, float(np.abs(s - sel["scores"]).max()))
    top = np.argsort(-s, axis=1)[:, :K]
    for a, b in zip(top, sel["experts"]):
        same_top += set(a) == set(b); n += 1
print("max |scores - W x| = %.3g" % max_abs)
print("top-8 match %d / %d" % (same_top, n))
mc = data["miss_count"]
print("plans missing:", int((mc < 0).sum()), " live misses/layer: %.3f" % mc[mc >= 0].mean())
print("score range: %.3f .. %.3f" % (data["scores"].min(), data["scores"].max()))
