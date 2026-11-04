// GPU decoder for gpucodec.c's v2 layout: one thread per bitstream, 32 streams
// per chunk, 24 chunks per expert (768 threads per expert). Writes the expert
// in its installed byte layout, ready for the routed kernels.
#include <metal_stdlib>
using namespace metal;

constant uint LIMIT = 11;
constant uint PER_FILL = 5;   // 64-bit window, 11-bit codes
constant uint GS = 32;
constant uint SPAN = 121;
constant uint CHUNK_GROUPS = 3872;
constant uint NCHUNKS = 24;
constant uint LUT = 1u << LIMIT;
constant uint ESC = 48;
constant uint KCODES[3] = {0, 1115136, 2230272};
constant uint KSCALES[3] = {991232, 2106368, 3221504};
constant uint KBIASES[3] = {1053184, 2168320, 3283456};

static inline uint be32(device const uint *p, uint w) {
  uint v = p[w];
  return (v << 24) | ((v & 0xFF00u) << 8) | ((v >> 8) & 0xFF00u) | (v >> 24);
}

struct Reader {
  device const uint *base;
  uint pos;
  ulong win;
};

static inline void fill(thread Reader &r) {
  uint w = r.pos >> 5, sh = r.pos & 31;
  ulong v = ((ulong)be32(r.base, w) << 32) | (ulong)be32(r.base, w + 1);
  v <<= sh;
  if (sh) v |= (ulong)be32(r.base, w + 2) >> (32 - sh);
  r.win = v;
}

static inline uint sym(thread Reader &r, device const ushort *lut) {
  ushort e = lut[(uint)(r.win >> (64 - LIMIT))];
  uint l = e >> 8;
  r.win <<= l;
  r.pos += l;
  return e & 0xFF;
}

static inline ushort f2bf(float f) {
  uint u = as_type<uint>(f);
  u = u + 0x7FFFu + ((u >> 16) & 1u);
  return (ushort)(u >> 16);
}

kernel void decode(device const uchar *enc [[buffer(0)]],
                   device const uint *index [[buffer(1)]],
                   device const ushort *tables [[buffer(2)]],
                   device uchar *out [[buffer(3)]],
                   constant uint &stride [[buffer(4)]],
                   constant uint &first [[buffer(5)]],
                   uint gid [[thread_position_in_grid]]) {
  uint e = first + gid / (NCHUNKS * GS), rem = gid % (NCHUNKS * GS), c = rem / GS, s = rem % GS;
  device const uchar *ex = enc + index[e];
  device const uint *coff = (device const uint *)ex;
  device const uchar *ch = ex + coff[c];
  device const uint *soff = (device const uint *)ch;
  device const uchar *lo = ch + 4 * (GS + 1);
  uint k = c / 8, g0 = (c % 8) * CHUNK_GROUPS;
  device const ushort *T = tables + k * 18 * LUT;
  device const ushort *SH = T + 16 * LUT, *BS = T + 17 * LUT;
  device uchar *o = out + (ulong)(e - first) * stride;
  device ushort *sc = (device ushort *)(o + KSCALES[k]) + g0;
  device ushort *bi = (device ushort *)(o + KBIASES[k]) + g0;
  device uint4 *cd = (device uint4 *)(o + KCODES[k] + g0 * 32);
  Reader r = {(device const uint *)(ch + soff[s]), 0, 0};
  for (uint g = s * SPAN; g < (s + 1) * SPAN; g++) {
    fill(r);
    uint hi = sym(r, SH), bs = sym(r, BS);
    ushort sv = (ushort)((hi << 8) | lo[g]);
    ushort b;
    uint z;
    if (bs == ESC) {
      fill(r);
      b = (ushort)(r.win >> 48);
      r.pos += 16;
      float q = rint(as_type<float>((uint)b << 16) / as_type<float>((uint)sv << 16));
      int zi = isfinite(q) ? (int)(-q) : 0;
      z = (uint)clamp(zi, 0, 15);
    } else {
      z = bs / 3;
      ushort pred = z == 0 ? (ushort)0 : f2bf(-(float)z * as_type<float>((uint)sv << 16));
      b = (ushort)(pred + (bs % 3) - 1);
    }
    sc[g] = sv;
    bi[g] = b;
    device const ushort *C = T + z * LUT;
    uint wds[8];
    for (uint j = 0; j < 32; j++) {
      if (j % PER_FILL == 0) fill(r);
      uint byte = sym(r, C);
      if ((j & 3) == 0) wds[j >> 2] = byte; else wds[j >> 2] |= byte << (8 * (j & 3));
    }
    cd[g * 2] = uint4(wds[0], wds[1], wds[2], wds[3]);
    cd[g * 2 + 1] = uint4(wds[4], wds[5], wds[6], wds[7]);
  }
}
