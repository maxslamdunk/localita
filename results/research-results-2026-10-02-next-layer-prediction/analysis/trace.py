"""Read a routing trace written by RoutingTraceWriter (see its doc comment)."""
import json, os
import numpy as np


def load(directory):
    meta = json.load(open(os.path.join(directory, "meta.json")))
    D, E, K = meta["hiddenSize"], meta["numExperts"], meta["topK"]
    rec = np.dtype([
        ("position", "<i4"), ("layer", "<i4"), ("miss_count", "<i4"),
        ("experts", "<i4", K), ("misses", "<i4", K),
        ("scores", "<f4", E),
        ("router_input", "<f2", D), ("layer_output", "<f2", D),
    ])
    assert rec.itemsize == meta["recordBytes"], (rec.itemsize, meta)
    data = np.memmap(os.path.join(directory, "trace.bin"), dtype=rec, mode="r")
    return meta, data


def router(directory, layer, meta):
    D, E = meta["hiddenSize"], meta["numExperts"]
    path = os.path.join(directory, "router_L%02d.f32" % layer)
    return np.fromfile(path, dtype="<f4").reshape(E, D)
