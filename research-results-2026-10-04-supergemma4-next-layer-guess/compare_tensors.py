"""Compare every resident tensor of two .gturbo installs, byte for byte.

Usage: compare_tensors.py <a.gturbo> <b.gturbo>

Decodes the resident index at the start of each model_weights.bin
(GTurboResidentIndexV1: 24-byte header, 72-byte entries) and compares each
tensor's weights, scales and biases. Prints, per tensor kind with the layer
number folded out, how many layers are identical and how many differ, and for
the differing ones the share of weight bytes that changed. Reads through mmap
and prints only the summary.
"""
import collections, mmap, os, re, struct, sys
import numpy as np


def entries(path):
    f = open(os.path.join(path, "model_weights.bin"), "rb")
    m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    _, _, n = struct.unpack_from("<QQQ", m, 0)
    out = {}
    for i in range(n):
        o = 24 + i * 72
        name_offset, name_length = struct.unpack_from("<IH", m, o)
        name = m[name_offset:name_offset + name_length].decode()
        fo, sz = struct.unpack_from("<QQ", m, o + 8)
        so, ss, bo, bs = struct.unpack_from("<QQQQ", m, o + 40)
        out[name] = ((fo, sz), (so, ss), (bo, bs))
    return m, out


ma, ea = entries(sys.argv[1])
mb, eb = entries(sys.argv[2])
assert ea.keys() == eb.keys()
counts = collections.defaultdict(lambda: [0, 0])
changed = collections.defaultdict(lambda: [0, 0])
for name in ea:
    parts_a = [ma[o:o + s] for o, s in ea[name]]
    parts_b = [mb[o:o + s] for o, s in eb[name]]
    kind = re.sub(r"\.\d+\.", ".N.", name)
    same = parts_a == parts_b
    counts[kind][0 if same else 1] += 1
    if not same and len(parts_a[0]) == len(parts_b[0]):
        x = np.frombuffer(parts_a[0], np.uint8)
        y = np.frombuffer(parts_b[0], np.uint8)
        changed[kind][0] += int((x != y).sum())
        changed[kind][1] += x.size
print("resident tensors: %d" % len(ea))
for kind, (same, differ) in sorted(counts.items()):
    extra = ""
    if differ and changed[kind][1]:
        extra = " (%.1f%% of weight bytes changed)" % (100 * changed[kind][0] / changed[kind][1])
    print("%-66s identical %3d  differ %3d%s" % (kind, same, differ, extra))
