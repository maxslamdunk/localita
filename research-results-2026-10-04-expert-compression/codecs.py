#!/usr/bin/env python3
"""Off-the-shelf codecs on a sample of installed experts: ratio and decode speed.

Single thread, M1 performance core (macOS schedules a busy Python thread there).
Decode speed is output bytes per second, best of 3, data already in memory.

    codecs.py <model.gturbo> [--per-layer N]
"""
import argparse
import ctypes
import json
import os
import time

import numpy as np
import zstandard

STRIDE = 3_358_720
lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
lib.compression_encode_buffer.restype = ctypes.c_size_t
lib.compression_decode_buffer.restype = ctypes.c_size_t
for fn in (lib.compression_encode_buffer, lib.compression_decode_buffer):
    fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
APPLE = {"LZ4": 0x100, "ZLIB": 0x205, "LZMA": 0x306, "LZFSE": 0x801, "LZBITMAP": 0x702, "BROTLI": 0xB02}


def apple_enc(alg, data):
    dst = ctypes.create_string_buffer(len(data) + 65536)
    n = lib.compression_encode_buffer(dst, len(dst), data, len(data), None, alg)
    return dst.raw[:n] if n else None


def apple_dec_fn(alg, comp, size):
    dst = ctypes.create_string_buffer(size)
    src = ctypes.create_string_buffer(comp, len(comp))

    def f():
        n = lib.compression_decode_buffer(dst, size, src, len(comp), None, alg)
        assert n == size, (n, size)
    return f


def chunks(b, n):
    return [b[i : i + n] for i in range(0, len(b), n)]


def best_time(f, reps=3):
    t = float("inf")
    for _ in range(reps):
        t0 = time.perf_counter()
        f()
        t = min(t, time.perf_counter() - t0)
    return t


def split_streams(blob, tens):
    """Codes of gate, up, down; then every scale and bias, high bytes then low bytes."""
    codes = b"".join(blob[t["offset"] : t["offset"] + t["size"]] for k, t in sorted(tens.items(), key=lambda kv: kv[1]["offset"]) if "bits" in t)
    sb = [blob[t["offset"] : t["offset"] + t["size"]] for k, t in sorted(tens.items(), key=lambda kv: kv[1]["offset"]) if "bits" not in t]
    u16 = np.frombuffer(b"".join(sb), np.uint16)
    hi = (u16 >> 8).astype(np.uint8).tobytes()
    lo = (u16 & 0xFF).astype(np.uint8).tobytes()
    return codes, hi, lo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--per-layer", type=int, default=4)
    args = ap.parse_args()
    layout = json.load(open(os.path.join(args.model, "packed_experts", "layout.json")))
    tens = layout["layers"][0]["experts"][0]["tensors"]
    end_used = max(t["offset"] + t["size"] for t in tens.values())
    pick = np.linspace(0, 127, args.per_layer).round().astype(int)

    blobs = []
    for entry in layout["layers"]:
        with open(os.path.join(args.model, "packed_experts", entry["file"]), "rb") as f:
            for e in pick:
                f.seek(int(e) * STRIDE)
                blobs.append(f.read(STRIDE))
    raw = len(blobs) * STRIDE
    print(f"{len(blobs)} experts ({args.per_layer} per layer), {raw / 1e6:.1f} MB; padding dropped from every variant below ({(STRIDE - end_used) / STRIDE:.2%})")

    results = []

    def run(name, encode, decoders):
        comp_total, t_total, out_total = 0, 0.0, 0
        for b in blobs:
            parts = encode(b[:end_used])
            comp_total += sum(len(c) for c, _ in parts)
            fs = [dec(c, n) for (c, n), dec in zip(parts, decoders(len(parts)))]
            t_total += best_time(lambda: [f() for f in fs])
            out_total += end_used
        r = comp_total / raw
        results.append((name, r, out_total / t_total / 1e9))
        print(f"  {name:44s} {r:.4f} of raw ({r - 1:+.2%})   decode {out_total / t_total / 1e9:.2f} GB/s", flush=True)

    def zdec(c, n):
        d = zstandard.ZstdDecompressor()
        return lambda: d.decompress(c, max_output_size=n)

    def zstd_whole(level, chunk=None):
        cctx = zstandard.ZstdCompressor(level=level)
        def enc(b):
            pieces = chunks(b, chunk) if chunk else [b]
            return [(cctx.compress(p), len(p)) for p in pieces]
        return enc

    print("\n## zstd, whole expert and independent chunks")
    for level in (1, 3, 9, 19):
        run(f"zstd -{level}, whole expert", zstd_whole(level), lambda n: [zdec] * n)
    for kib in (64, 128, 256):
        run(f"zstd -3, {kib} KiB chunks", zstd_whole(3, kib * 1024), lambda n: [zdec] * n)
    run("zstd -19, 128 KiB chunks", zstd_whole(19, 128 * 1024), lambda n: [zdec] * n)

    print("\n## zstd on split streams (codes | scale+bias high bytes | low bytes)")
    for level in (3, 19):
        cctx = zstandard.ZstdCompressor(level=level)
        def enc(b, cctx=cctx):
            return [(cctx.compress(s), len(s)) for s in split_streams(b, tens)]
        run(f"zstd -{level}, split streams", enc, lambda n: [zdec] * n)

    print("\n## Apple libcompression, whole expert")
    for name, alg in APPLE.items():
        def enc(b, alg=alg):
            c = apple_enc(alg, b)
            return [(c, len(b))] if c else [(b, len(b))]
        run(f"{name}", enc, lambda n, alg=alg: [lambda c, s: apple_dec_fn(alg, c, s)] * n)


if __name__ == "__main__":
    main()
