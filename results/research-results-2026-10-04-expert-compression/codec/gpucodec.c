// gpucodec: excodec's model in a layout a GPU can decode, one thread per stream.
//
// Same symbols and tables as excodec.c. Per chunk (3,872 groups) there are
// GS = 32 bitstreams, stream s holding the contiguous groups
// [121 s, 121 (s + 1)), each group as: scale-high symbol, bias symbol (an
// escape is followed by the raw 16 bits), 32 code-byte symbols. Streams start
// on 4-byte boundaries so a GPU thread can read aligned words.
//
// Chunk: u32 off[GS + 1] (stream byte offsets from the chunk start) |
//        lo bytes [3872] | streams
// Expert: u32 chunk_off[NCHUNKS + 1] (from the expert start) | chunks
//
//   cc -O3 -DNSTREAMS=8 -o gpucodec gpucodec.c
//   gpucodec <packed_experts> <layer> <outdir> <n experts>
// writes tables.bin, enc.bin, enc_index.bin, orig.bin into outdir and reports
// the v2 ratio and CPU decode speed.

#define EXCODEC_NO_MAIN
#include "excodec.c"

#define GS 32
#define SPAN (CHUNK_GROUPS / GS) /* 121 groups per stream */
#define CHUNK_HDR (4 * (GS + 1))

static size_t encode_chunk_v2(const Tables *t, int k, const uint8_t *e, uint32_t g0, uint8_t *out) {
  const Kind *K = &KINDS[k];
  const uint16_t *sc = (const uint16_t *)(e + K->scales) + g0, *bi = (const uint16_t *)(e + K->biases) + g0;
  const uint8_t *cd = e + K->codes + (size_t)g0 * 32;
  uint32_t *off = (uint32_t *)out;
  uint8_t *lo = out + CHUNK_HDR;
  for (uint32_t g = 0; g < CHUNK_GROUPS; g++) lo[g] = sc[g] & 0xFF;
  size_t pos = CHUNK_HDR + CHUNK_GROUPS;
  pos = (pos + 3) & ~(size_t)3;
  const Huff *SH = &t->shi[k], *BS = &t->bias[k];
  for (int s = 0; s < GS; s++) {
    off[s] = (uint32_t)pos;
    BW w = {out + pos, CHUNK_OUT * 2, 0, 0, 0};
    for (uint32_t g = s * SPAN; g < (uint32_t)(s + 1) * SPAN; g++) {
      bw_put(&w, SH->code[sc[g] >> 8], SH->len[sc[g] >> 8]);
      int z;
      int bs = bias_symbol(sc[g], bi[g], &z);
      bw_put(&w, BS->code[bs], BS->len[bs]);
      if (bs == ESC) bw_put(&w, bi[g], 16);
      const Huff *H = &t->code[k][z];
      for (int j = 0; j < 32; j++) bw_put(&w, H->code[cd[g * 32 + j]], H->len[cd[g * 32 + j]]);
    }
    bw_flush(&w);
    pos += w.pos;
    pos = (pos + 3) & ~(size_t)3;
  }
  off[GS] = (uint32_t)pos;
  return pos;
}

static inline uint32_t peek_bits(const uint8_t *base, uint64_t pos, int n) {
  return (uint32_t)((load_be64(base + (pos >> 3)) << (pos & 7)) >> (64 - n));
}

// CPU reference decoder for the v2 layout (one stream at a time, simple)
static void decode_chunk_v2(const Tables *t, int k, const uint8_t *in, uint8_t *e, uint32_t g0) {
  const Kind *K = &KINDS[k];
  uint16_t *sc = (uint16_t *)(e + K->scales) + g0, *bi = (uint16_t *)(e + K->biases) + g0;
  uint8_t *cd = e + K->codes + (size_t)g0 * 32;
  const uint32_t *off = (const uint32_t *)in;
  const uint8_t *lo = in + CHUNK_HDR;
  const uint16_t *SH = t->shi[k].lut, *BS = t->bias[k].lut;
  for (int s = 0; s < GS; s++) {
    RD r = {in + off[s], 0, 0, 0};
    for (uint32_t g = s * SPAN; g < (uint32_t)(s + 1) * SPAN; g++) {
      rd_fill(&r);
      int hi = rd_sym(&r, SH, LIMIT), bs = rd_sym(&r, BS, LIMIT);
      uint16_t sv = (uint16_t)((hi << 8) | lo[g]), b;
      int z;
      if (bs == ESC) { b = (uint16_t)peek_bits(r.base, r.pos, 16); r.pos += 16; z = zero_code(sv, b); }
      else { z = bs / 3; b = (uint16_t)(bias_pred(z, sv) + (bs % 3) - 1); }
      sc[g] = sv; bi[g] = b;
      const uint16_t *T = t->code[k][z].lut;
      for (int j = 0; j < 32; j++) {
        if ((j % PER_FILL) == 0) rd_fill(&r);
        cd[g * 32 + j] = (uint8_t)rd_sym(&r, T, LIMIT);
      }
    }
  }
}

int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: %s <packed_experts> <layer> <outdir> <n>\n", argv[0]); return 2; }
  const char *dir = argv[1], *outdir = argv[3];
  int layer = atoi(argv[2]), n = atoi(argv[4]);
  uint8_t *raw = malloc(STRIDE);
  Counts *c = calloc(1, sizeof(Counts));
  for (int x = 0; x < NEXPERTS; x += 4) {
    if (read_expert(dir, layer, x, raw)) return 1;
    count_expert(c, raw);
  }
  Tables *t = calloc(1, sizeof(Tables));
  build_tables(t, c);

  char path[1200];
  // tables: per kind, 16 code LUTs then the scale-high LUT then the bias LUT, 2^LIMIT u16 each
  snprintf(path, sizeof path, "%s/tables.bin", outdir);
  FILE *ft = fopen(path, "wb");
  for (int k = 0; k < NKINDS; k++) {
    for (int z = 0; z < 16; z++) fwrite(t->code[k][z].lut, 2, 1 << LIMIT, ft);
    fwrite(t->shi[k].lut, 2, 1 << LIMIT, ft);
    fwrite(t->bias[k].lut, 2, 1 << LIMIT, ft);
  }
  fclose(ft);

  snprintf(path, sizeof path, "%s/enc.bin", outdir);
  FILE *fe = fopen(path, "wb");
  snprintf(path, sizeof path, "%s/orig.bin", outdir);
  FILE *fo = fopen(path, "wb");
  uint32_t *index = calloc(n + 1, 4);
  uint8_t *buf = calloc(1, STRIDE * 2);
  uint8_t *chk = calloc(1, STRIDE);
  uint8_t **encs = calloc(n, sizeof(uint8_t *));
  size_t total = 0, bad = 0;
  for (int i = 0; i < n; i++) {
    int x = 1 + 2 * i;
    if (read_expert(dir, layer, x, raw)) return 1;
    uint32_t *coff = (uint32_t *)buf;
    size_t o = 4 * (NCHUNKS + 1);
    for (int k = 0; k < NCHUNKS; k++) {
      coff[k] = (uint32_t)o;
      o += encode_chunk_v2(t, k / CHUNKS_PER_KIND, raw, (uint32_t)(k % CHUNKS_PER_KIND) * CHUNK_GROUPS, buf + o);
    }
    coff[NCHUNKS] = (uint32_t)o;
    memset(buf + o, 0, 16);
    o = (o + 15) & ~(size_t)15;
    memset(chk, 0, STRIDE);
    for (int k = 0; k < NCHUNKS; k++)
      decode_chunk_v2(t, k / CHUNKS_PER_KIND, buf + coff[k], chk, (uint32_t)(k % CHUNKS_PER_KIND) * CHUNK_GROUPS);
    if (memcmp(chk, raw, USED)) bad++;
    index[i] = (uint32_t)total;
    fwrite(buf, 1, o, fe);
    fwrite(raw, 1, STRIDE, fo);
    encs[i] = malloc(o + 16); memcpy(encs[i], buf, o); memset(encs[i] + o, 0, 16);
    total += o;
  }
  index[n] = (uint32_t)total;
  fwrite(buf, 1, 64, fe); // slack for word reads past the last stream
  fclose(fe); fclose(fo);
  snprintf(path, sizeof path, "%s/enc_index.bin", outdir);
  FILE *fi = fopen(path, "wb");
  fwrite(index, 4, n + 1, fi);
  fclose(fi);
  printf("layer %d, %d experts, v2 layout (%d streams per chunk): %.4f of raw (%+.2f%%); CPU reference round trip %s\n",
         layer, n, GS, (double)total / ((double)n * STRIDE), ((double)total / ((double)n * STRIDE) - 1) * 100, bad ? "FAILED" : "bit-exact");
  double best = 1e9;
  for (int trial = 0; trial < 3; trial++) {
    double a = now();
    for (int i = 0; i < n; i++) {
      const uint32_t *coff = (const uint32_t *)encs[i];
      for (int k = 0; k < NCHUNKS; k++)
        decode_chunk_v2(t, k / CHUNKS_PER_KIND, encs[i] + coff[k], chk, (uint32_t)(k % CHUNKS_PER_KIND) * CHUNK_GROUPS);
    }
    double d = now() - a;
    if (d < best) best = d;
  }
  printf("CPU reference decoder (one stream at a time, not tuned): %.2f GB/s\n", (double)n * USED / best / 1e9);
  return bad ? 1 : 0;
}
