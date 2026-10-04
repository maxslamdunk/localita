// excodec: a purpose-built lossless codec for TurboFieldfare's routed experts.
//
// Prototype for measurement only (ratio, bit-exact round trip, decode speed).
// One expert = 24 independent chunks of 3,872 affine groups (88 rows of gate
// or up, 352 rows of down), 139,392 output bytes each. Per group:
//   - scale: high byte Huffman-coded, low byte stored raw;
//   - bias: symbol (z, r) Huffman-coded, where z is the code of 0.0 in the
//     group and bias = bf16(-z * scale) + r, r in {-1, 0, 1}; else an escape
//     and the raw 16 bits;
//   - 32 code bytes (64 INT4 codes): Huffman over bytes, table chosen by z.
// Code bytes of a chunk go round-robin by group into NSTREAMS bitstreams so
// the decoder runs NSTREAMS independent dependency chains.
//
// Tables are fitted on even-numbered experts and scored on odd ones.
//
//   cc -O3 -o excodec excodec.c
//   excodec <packed_experts dir> [--limit L] [--tables layer|global]
//           [--test-step N] [--threads N] [--shift]

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define NLAYERS 30
#define NEXPERTS 128
#define STRIDE 3358720
#define USED 3345408
#define NKINDS 3
#define CHUNK_GROUPS 3872
#define CHUNKS_PER_KIND 8
#define NCHUNKS (NKINDS * CHUNKS_PER_KIND)
#define CHUNK_OUT (CHUNK_GROUPS * 36)
#ifndef NSTREAMS
#define NSTREAMS 4
#endif
#define MAXL 15
#define NBIAS 49 /* 16 z x 3 residuals + escape */
#define ESC 48
#ifndef LIMIT
#define LIMIT 11
#endif
#define LIMIT_DEFAULT LIMIT

typedef struct { uint32_t codes, scales, biases, rows, groups_per_row; } Kind;
static const Kind KINDS[NKINDS] = {
    {0, 991232, 1053184, 704, 44},        // gate
    {1115136, 2106368, 2168320, 704, 44}, // up
    {2230272, 3221504, 3283456, 2816, 11} // down
};

static int g_limit = LIMIT_DEFAULT, g_global = 0, g_shift = 0;

// ---------- bf16 ----------
static inline float bf2f(uint16_t b) { uint32_t u = (uint32_t)b << 16; float f; memcpy(&f, &u, 4); return f; }
static inline uint16_t f2bf(float f) { uint32_t u; memcpy(&u, &f, 4); u = u + 0x7FFF + ((u >> 16) & 1); return (uint16_t)(u >> 16); }
static inline int zero_code(uint16_t s, uint16_t b) {
  float sf = bf2f(s), bf = bf2f(b);
  float q = rintf(bf / sf);
  if (!isfinite(q)) return 0;
  int z = (int)-q;
  return z < 0 ? 0 : z > 15 ? 15 : z;
}
static inline uint16_t bias_pred(int z, uint16_t s) { return z == 0 ? 0 : f2bf(-(float)z * bf2f(s)); }

// ---------- Huffman ----------
typedef struct { uint8_t len[256]; uint32_t code[256]; uint16_t lut[1 << MAXL]; int nsym; } Huff;

static void huff_lengths(const uint64_t *freq, int n, int limit, uint8_t *len) {
  uint64_t f[256];
  for (int i = 0; i < n; i++) f[i] = freq[i];
  int nz = 0;
  for (int i = 0; i < n; i++) nz += f[i] > 0;
  if (nz < 2) { // degenerate: give every symbol a code so anything decodes
    for (int i = 0; i < n; i++) f[i] = f[i] + 1;
  }
  for (;;) {
    // O(n^2) Huffman, n <= 256: fine for a prototype
    int parent[512], m = 0; uint64_t w[512]; int alive[512];
    int leaf_of[256];
    for (int i = 0; i < n; i++) if (f[i]) { w[m] = f[i]; alive[m] = 1; parent[m] = -1; leaf_of[i] = m; m++; } else leaf_of[i] = -1;
    int nodes = m, left = m;
    while (left > 1) {
      int a = -1, b = -1;
      for (int i = 0; i < nodes; i++) if (alive[i]) {
        if (a < 0 || w[i] < w[a]) { b = a; a = i; } else if (b < 0 || w[i] < w[b]) b = i;
      }
      w[nodes] = w[a] + w[b]; alive[nodes] = 1; parent[nodes] = -1;
      alive[a] = alive[b] = 0; parent[a] = parent[b] = nodes; nodes++; left--;
    }
    int maxl = 0;
    for (int i = 0; i < n; i++) {
      if (leaf_of[i] < 0) { len[i] = 0; continue; }
      int l = 0;
      for (int k = leaf_of[i]; parent[k] >= 0; k = parent[k]) l++;
      len[i] = (uint8_t)l; if (l > maxl) maxl = l;
    }
    if (maxl <= limit) return;
    for (int i = 0; i < n; i++) if (f[i]) f[i] = f[i] / 2 + 1; // flatten and retry
  }
}

static void huff_build(Huff *h, const uint64_t *freq, int n) {
  memset(h, 0, sizeof *h);
  h->nsym = n;
  huff_lengths(freq, n, g_limit, h->len);
  uint32_t code = 0;
  for (int l = 1; l <= g_limit; l++) {
    for (int s = 0; s < n; s++) if (h->len[s] == l) {
      h->code[s] = code;
      uint32_t lo = code << (g_limit - l), hi = (code + 1) << (g_limit - l);
      for (uint32_t k = lo; k < hi; k++) h->lut[k] = (uint16_t)(s | (l << 8));
      code++;
    }
    code <<= 1;
  }
}

// ---------- bit I/O (MSB first) ----------
typedef struct { uint8_t *buf; size_t cap, pos; uint64_t acc; int n; } BW;
static void bw_put(BW *w, uint32_t code, int len) {
  w->acc = (w->acc << len) | code; w->n += len;
  while (w->n >= 8) { w->buf[w->pos++] = (uint8_t)(w->acc >> (w->n - 8)); w->n -= 8; }
}
static void bw_flush(BW *w) { if (w->n) { w->buf[w->pos++] = (uint8_t)(w->acc << (8 - w->n)); w->n = 0; } }

static inline uint64_t load_be64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return __builtin_bswap64(v); }

// Simple absolute-position reader: reload from (pos >> 3) every few symbols.
typedef struct { const uint8_t *base; uint64_t pos; uint64_t bits; int left; } RD;
static inline void rd_fill(RD *r) {
  r->bits = load_be64(r->base + (r->pos >> 3)) << (r->pos & 7);
  r->left = 56 + 0; // at least 57 valid bits after the shift of <= 7
}
static inline int rd_sym(RD *r, const uint16_t *lut, int L) {
  uint16_t e = lut[r->bits >> (64 - L)];
  int l = e >> 8;
  r->bits <<= l; r->pos += l;
  return e & 0xFF;
}

// ---------- tables ----------
typedef struct {
  Huff code[NKINDS][16];
  Huff shi[NKINDS];
  Huff bias[NKINDS];
} Tables;

typedef struct {
  uint64_t code[NKINDS][16][256];
  uint64_t shi[NKINDS][256];
  uint64_t bias[NKINDS][NBIAS];
} Counts;

static inline uint8_t shift_byte(uint8_t b, int z, int dir) {
  int lo = b & 15, hi = b >> 4;
  lo = (lo - dir * z) & 15; hi = (hi - dir * z) & 15;
  return (uint8_t)(lo | (hi << 4));
}

static int bias_symbol(uint16_t s, uint16_t b, int *zout) {
  int z = zero_code(s, b);
  *zout = z;
  int r = (int)b - (int)bias_pred(z, s);
  if (r < -1 || r > 1) return ESC;
  return z * 3 + (r + 1);
}

static void count_expert(Counts *c, const uint8_t *e) {
  for (int k = 0; k < NKINDS; k++) {
    const Kind *K = &KINDS[k];
    uint32_t ng = K->rows * K->groups_per_row;
    const uint16_t *sc = (const uint16_t *)(e + K->scales), *bi = (const uint16_t *)(e + K->biases);
    const uint8_t *cd = e + K->codes;
    for (uint32_t g = 0; g < ng; g++) {
      int z;
      int bs = bias_symbol(sc[g], bi[g], &z);
      c->bias[k][bs]++;
      c->shi[k][sc[g] >> 8]++;
      int t = g_shift ? 0 : z;
      for (int j = 0; j < 32; j++) {
        uint8_t b = cd[g * 32 + j];
        c->code[k][t][g_shift ? shift_byte(b, z, 1) : b]++;
      }
    }
  }
}

static void build_tables(Tables *t, const Counts *c) {
  for (int k = 0; k < NKINDS; k++) {
    for (int z = 0; z < 16; z++) {
      uint64_t tot = 0;
      for (int s = 0; s < 256; s++) tot += c->code[k][z][s];
      uint64_t f[256];
      // every byte must stay codable: add 1 to every count
      for (int s = 0; s < 256; s++) f[s] = c->code[k][z][s] + 1;
      if (tot == 0) { // unseen z: borrow the most common table's shape
        for (int s = 0; s < 256; s++) f[s] = c->code[k][g_shift ? 0 : 8][s] + 1;
      }
      huff_build(&t->code[k][z], f, 256);
    }
    uint64_t f[256];
    for (int s = 0; s < 256; s++) f[s] = c->shi[k][s] + 1;
    huff_build(&t->shi[k], f, 256);
    uint64_t fb[NBIAS];
    for (int s = 0; s < NBIAS; s++) fb[s] = c->bias[k][s] + 1;
    huff_build(&t->bias[k], fb, NBIAS);
  }
}

// ---------- chunk format ----------
// [u32 n_esc][u32 len_sb][u32 len_code[NSTREAMS]][lo bytes CHUNK_GROUPS][esc u16 x n_esc][sb][code0..]
#define HDR (4 * (2 + NSTREAMS))

static size_t encode_chunk(const Tables *t, int k, const uint8_t *e, uint32_t g0, uint8_t *out, size_t stats[4]) {
  const Kind *K = &KINDS[k];
  const uint16_t *sc = (const uint16_t *)(e + K->scales) + g0, *bi = (const uint16_t *)(e + K->biases) + g0;
  const uint8_t *cd = e + K->codes + (size_t)g0 * 32;
  uint8_t *lo = out + HDR;
  uint16_t esc[CHUNK_GROUPS]; uint32_t nesc = 0;
  static __thread uint8_t cbuf[NSTREAMS][CHUNK_OUT];
  BW cw[NSTREAMS];
  for (int s = 0; s < NSTREAMS; s++) cw[s] = (BW){cbuf[s], CHUNK_OUT, 0, 0, 0};
  const Huff *SH = &t->shi[k], *BS = &t->bias[k];
  size_t side_bits = 0;
  for (uint32_t g = 0; g < CHUNK_GROUPS; g++) {
    BW *w = &cw[g % NSTREAMS];
    lo[g] = sc[g] & 0xFF;
    bw_put(w, SH->code[sc[g] >> 8], SH->len[sc[g] >> 8]);
    int z;
    int bs = bias_symbol(sc[g], bi[g], &z);
    bw_put(w, BS->code[bs], BS->len[bs]);
    side_bits += SH->len[sc[g] >> 8] + BS->len[bs];
    if (bs == ESC) esc[nesc++] = bi[g];
    const Huff *H = &t->code[k][g_shift ? 0 : z];
    for (int j = 0; j < 32; j++) {
      uint8_t b = cd[g * 32 + j];
      if (g_shift) b = shift_byte(b, z, 1);
      bw_put(w, H->code[b], H->len[b]);
    }
  }
  uint32_t *hdr = (uint32_t *)out;
  hdr[0] = nesc; hdr[1] = 0;
  uint8_t *p = lo + CHUNK_GROUPS;
  memcpy(p, esc, nesc * 2); p += nesc * 2;
  stats[0] += CHUNK_GROUPS + nesc * 2 + HDR; stats[1] += side_bits / 8;
  for (int s = 0; s < NSTREAMS; s++) {
    bw_flush(&cw[s]);
    hdr[2 + s] = (uint32_t)cw[s].pos;
    memcpy(p, cbuf[s], cw[s].pos); p += cw[s].pos;
    stats[2] += cw[s].pos;
  }
  stats[2] -= side_bits / 8;
  return (size_t)(p - out);
}

#ifndef LIMIT
#define LIMIT 11
#endif
#define PER_FILL (56 / LIMIT)

static void decode_chunk(const Tables *t, int k, const uint8_t *in, uint8_t *e, uint32_t g0) {
  const Kind *K = &KINDS[k];
  uint16_t *sc = (uint16_t *)(e + K->scales) + g0, *bi = (uint16_t *)(e + K->biases) + g0;
  uint8_t *cd = e + K->codes + (size_t)g0 * 32;
  const uint32_t *hdr = (const uint32_t *)in;
  uint32_t nesc = hdr[0];
  const uint8_t *lo = in + HDR;
  const uint16_t *esc = (const uint16_t *)(lo + CHUNK_GROUPS);
  const uint8_t *cp = lo + CHUNK_GROUPS + nesc * 2;
  const uint16_t *SH = t->shi[k].lut, *BS = t->bias[k].lut;
  uint32_t ke = 0;
  uint8_t his[CHUNK_GROUPS], bss[CHUNK_GROUPS];
  static const uint8_t ZOF[NBIAS] = {0,0,0,1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6,7,7,7,8,8,8,9,9,9,10,10,10,11,11,11,12,12,12,13,13,13,14,14,14,15,15,15,0};
  RD r[NSTREAMS];
  for (int s = 0; s < NSTREAMS; s++) { r[s] = (RD){cp, 0, 0, 0}; cp += hdr[2 + s]; }
  for (uint32_t g = 0; g < CHUNK_GROUPS; g += NSTREAMS) {
    const uint16_t *T[NSTREAMS];
    uint8_t *o[NSTREAMS];
    int zz[NSTREAMS];
    for (int s = 0; s < NSTREAMS; s++) {
      rd_fill(&r[s]);
      int hi = rd_sym(&r[s], SH, LIMIT);
      int bs = rd_sym(&r[s], BS, LIMIT);
      his[g + s] = (uint8_t)hi; bss[g + s] = (uint8_t)bs;
      int z = ZOF[bs];
      if (__builtin_expect(bs == ESC, 0)) z = zero_code((uint16_t)((hi << 8) | lo[g + s]), esc[ke++]);
      zz[s] = z;
      T[s] = t->code[k][g_shift ? 0 : z].lut;
      o[s] = cd + (size_t)(g + s) * 32;
    }
    // the first window still holds PER_FILL - 2 symbols
#if NSTREAMS == 8 && !defined(GENERIC_LOOP)
    {
#define DECL(s) uint64_t b##s = r[s].bits, p##s = r[s].pos; const uint16_t *t##s = T[s]; uint8_t *o##s = o[s];
#define SYM(s) { uint16_t e = t##s[b##s >> (64 - LIMIT)]; unsigned l = e >> 8; b##s <<= l; p##s += l; o##s[j] = (uint8_t)e; }
#define FILL(s) b##s = load_be64(r[s].base + (p##s >> 3)) << (p##s & 7);
#define ALL(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7)
      ALL(DECL)
      int j = 0;
      for (; j < PER_FILL - 2; j++) { ALL(SYM) }
      while (j < 32) {
        ALL(FILL)
        if (32 - j >= PER_FILL) { for (int q = 0; q < PER_FILL; q++, j++) { ALL(SYM) } }
        else { while (j < 32) { ALL(SYM) j++; } }
      }
#define BACK(s) r[s].bits = b##s; r[s].pos = p##s;
      ALL(BACK)
    }
#else
    int j = 0;
    for (; j < PER_FILL - 2; j++)
      for (int s = 0; s < NSTREAMS; s++) o[s][j] = (uint8_t)rd_sym(&r[s], T[s], LIMIT);
    while (j < 32) {
      int n = 32 - j < PER_FILL ? 32 - j : PER_FILL;
      for (int s = 0; s < NSTREAMS; s++) rd_fill(&r[s]);
      for (int q = 0; q < n; q++, j++)
        for (int s = 0; s < NSTREAMS; s++) o[s][j] = (uint8_t)rd_sym(&r[s], T[s], LIMIT);
    }
#endif
    if (g_shift)
      for (int s = 0; s < NSTREAMS; s++)
        for (int jj = 0; jj < 32; jj++) o[s][jj] = shift_byte(o[s][jj], zz[s], -1);
  }
  ke = 0;
  for (uint32_t g = 0; g < CHUNK_GROUPS; g++) {
    uint16_t sv = (uint16_t)((his[g] << 8) | lo[g]);
    int bs = bss[g];
    sc[g] = sv;
    bi[g] = bs == ESC ? esc[ke++] : (uint16_t)(bias_pred(ZOF[bs], sv) + (bs % 3) - 1);
  }
}

#if NSTREAMS == 8
static void decode_chunk8(const Tables *t, int k, const uint8_t *in, uint8_t *e, uint32_t g0) {
  const Kind *K = &KINDS[k];
  uint16_t *sc = (uint16_t *)(e + K->scales) + g0, *bi = (uint16_t *)(e + K->biases) + g0;
  uint8_t *cd = e + K->codes + (size_t)g0 * 32;
  const uint32_t *hdr = (const uint32_t *)in;
  uint32_t nesc = hdr[0];
  const uint8_t *lo = in + HDR;
  const uint16_t *esc = (const uint16_t *)(lo + CHUNK_GROUPS);
  const uint8_t *cp = lo + CHUNK_GROUPS + nesc * 2;
  const uint16_t *SH = t->shi[k].lut, *BS = t->bias[k].lut;
  const Huff *CT = t->code[k];
  uint8_t his[CHUNK_GROUPS], bss[CHUNK_GROUPS];
  static const uint8_t ZOF[NBIAS] = {0,0,0,1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6,7,7,7,8,8,8,9,9,9,10,10,10,11,11,11,12,12,12,13,13,13,14,14,14,15,15,15,0};
  uint32_t ke = 0;
#define ALL8(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7)
#define BASE(s) const uint8_t *q##s = cp; cp += hdr[2 + s]; uint64_t b##s, p##s = 0;
  ALL8(BASE)
#define F(s) b##s = load_be64(q##s + (p##s >> 3)) << (p##s & 7);
#define S(s, lut, dst) { uint16_t e_ = (lut)[b##s >> (64 - LIMIT)]; unsigned l_ = e_ >> 8; b##s <<= l_; p##s += l_; dst = (uint8_t)e_; }
  for (uint32_t g = 0; g < CHUNK_GROUPS; g += 8) {
#define SIDE(s) const uint16_t *t##s; uint8_t *o##s = cd + (size_t)(g + s) * 32; { \
      F(s) uint8_t hi_, bs_; S(s, SH, hi_) S(s, BS, bs_) his[g + s] = hi_; bss[g + s] = bs_; \
      int z_ = ZOF[bs_]; \
      if (__builtin_expect(bs_ == ESC, 0)) z_ = zero_code((uint16_t)((hi_ << 8) | lo[g + s]), esc[ke++]); \
      t##s = CT[z_].lut; }
    ALL8(SIDE)
#define C(s) S(s, t##s, o##s[j])
    int j = 0;
    for (; j < PER_FILL - 2; j++) { ALL8(C) }
    for (; j + PER_FILL <= 32;) { ALL8(F) for (int q = 0; q < PER_FILL; q++, j++) { ALL8(C) } }
    if (j < 32) { ALL8(F) for (; j < 32; j++) { ALL8(C) } }
  }
  ke = 0;
  for (uint32_t g = 0; g < CHUNK_GROUPS; g++) {
    uint16_t sv = (uint16_t)((his[g] << 8) | lo[g]);
    int bs = bss[g];
    sc[g] = sv;
    bi[g] = bs == ESC ? esc[ke++] : (uint16_t)(bias_pred(ZOF[bs], sv) + (bs % 3) - 1);
  }
}
#define DECODE (g_shift ? decode_chunk : decode_chunk8)
#else
#define DECODE decode_chunk
#endif

// ---------- driver ----------
static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }

static int read_expert(const char *dir, int layer, int expert, uint8_t *buf) {
  char path[1024];
  snprintf(path, sizeof path, "%s/layer_%02d.bin", dir, layer);
  int fd = open(path, O_RDONLY);
  if (fd < 0) { perror(path); return -1; }
  ssize_t n = pread(fd, buf, STRIDE, (off_t)expert * STRIDE);
  close(fd);
  return n == STRIDE ? 0 : -1;
}

typedef struct { uint8_t *data; size_t off[NCHUNKS + 1]; } Enc;

#ifndef EXCODEC_NO_MAIN
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <packed_experts dir> [--limit L] [--tables layer|global] [--test-step N] [--threads N] [--shift]\n", argv[0]); return 2; }
  const char *dir = argv[1];
  int test_step = 8, threads = 1;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--limit")) { fprintf(stderr, "build with -DLIMIT=N instead\n"); return 2; }
    else if (!strcmp(argv[i], "--tables")) g_global = !strcmp(argv[++i], "global");
    else if (!strcmp(argv[i], "--test-step")) test_step = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--threads")) threads = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--shift")) g_shift = 1;
  }
  if (g_limit > MAXL || 56 / g_limit < 2) { fprintf(stderr, "limit must be <= 15\n"); return 2; }

  uint8_t *buf = malloc(STRIDE);
  int nlt = g_global ? 1 : NLAYERS;
  Counts *counts = calloc(nlt, sizeof(Counts));
  Tables *tables = calloc(nlt, sizeof(Tables));
  double t0 = now();
  // fit on even experts (every 4th even expert keeps the fit pass short)
  for (int l = 0; l < NLAYERS; l++)
    for (int x = 0; x < NEXPERTS; x += 4) {
      if (read_expert(dir, l, x, buf)) return 1;
      count_expert(&counts[g_global ? 0 : l], buf);
    }
  for (int i = 0; i < nlt; i++) build_tables(&tables[i], &counts[i]);
  fprintf(stderr, "fit %.1fs\n", now() - t0);

  // test on odd experts 1, 1+step, ...: encode, decode, compare one at a time;
  // keep at most TIMED encodings, spread evenly, for the speed measurement
  enum { TIMED = 120, RING = 8 };
  int ntest = 0;
  for (int x = 1; x < NEXPERTS; x += test_step) ntest++;
  int total = NLAYERS * ntest, keep_every = total > TIMED ? total / TIMED : 1;
  Enc *enc = calloc(TIMED, sizeof(Enc));
  int *enc_layer = calloc(TIMED, sizeof(int));
  int nkept = 0;
  size_t stats[4] = {0}, comp = 0, comp_aligned = 0, bad = 0;
  uint8_t *orig = malloc(STRIDE), *chk = calloc(1, STRIDE);
  int idx = 0;
  for (int l = 0; l < NLAYERS; l++)
    for (int x = 1; x < NEXPERTS; x += test_step, idx++) {
      if (read_expert(dir, l, x, orig)) return 1;
      const Tables *t = &tables[g_global ? 0 : l];
      uint8_t *tmp = malloc(USED + NCHUNKS * 4096);
      Enc e1;
      size_t o = 0;
      for (int c = 0; c < NCHUNKS; c++) {
        e1.off[c] = o;
        o += encode_chunk(t, c / CHUNKS_PER_KIND, orig, (uint32_t)(c % CHUNKS_PER_KIND) * CHUNK_GROUPS, tmp + o, stats);
      }
      e1.off[NCHUNKS] = o;
      e1.data = realloc(tmp, o + 64);
      memset(e1.data + o, 0, 64);
      size_t with_index = o + 4 * NCHUNKS; // chunk offset table
      comp += with_index;
      comp_aligned += (with_index + 4095) / 4096 * 4096;
      for (int c = 0; c < NCHUNKS; c++)
        DECODE(t, c / CHUNKS_PER_KIND, e1.data + e1.off[c], chk, (uint32_t)(c % CHUNKS_PER_KIND) * CHUNK_GROUPS);
      if (memcmp(chk, orig, USED)) bad++;
      if (idx % keep_every == 0 && nkept < TIMED) { enc[nkept] = e1; enc_layer[nkept++] = l; }
      else free(e1.data);
    }
  double raw = (double)total * STRIDE;
  printf("limit %d, tables %s, %s, %d test experts (odd, step %d)\n", g_limit, g_global ? "global per kind" : "per layer and kind",
         g_shift ? "codes shifted by z, one table per kind" : "one code table per z", total, test_step);
  printf("  size: %.4f of raw (%+.2f%%), 4 KiB-aligned per expert %.4f (%+.2f%%)\n", comp / raw, (comp / raw - 1) * 100,
         comp_aligned / raw, (comp_aligned / raw - 1) * 100);
  printf("  streams, bits per unit: codes %.4f/code, scale-hi+bias %.3f/group, raw lo+esc+hdr %.3f/group\n",
         stats[2] * 8.0 / ((double)total * 5947392), stats[1] * 8.0 / ((double)total * 92928), stats[0] * 8.0 / ((double)total * 92928));
  printf("  round trip: %s (%zu of %d experts differ)\n", bad ? "FAILED" : "bit-exact", bad, total);

  // speed: decode the kept experts into a ring of RING slot-sized buffers
  uint8_t *out = calloc(RING, STRIDE);
  for (int rep = 0; rep < 2; rep++) {
    double best = 1e9;
    for (int trial = 0; trial < 3; trial++) {
      double a = now();
      if (threads == 1) {
        for (int i = 0; i < nkept; i++)
          for (int c = 0; c < NCHUNKS; c++)
            DECODE(&tables[g_global ? 0 : enc_layer[i]], c / CHUNKS_PER_KIND, enc[i].data + enc[i].off[c], out + (size_t)(i % RING) * STRIDE,
                   (uint32_t)(c % CHUNKS_PER_KIND) * CHUNK_GROUPS);
      } else {
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        dispatch_apply((size_t)nkept * NCHUNKS, q, ^(size_t j) {
          int i = (int)(j / NCHUNKS), c = (int)(j % NCHUNKS);
          DECODE(&tables[g_global ? 0 : enc_layer[i]], c / CHUNKS_PER_KIND, enc[i].data + enc[i].off[c], out + (size_t)(i % RING) * STRIDE,
                 (uint32_t)(c % CHUNKS_PER_KIND) * CHUNK_GROUPS);
        });
      }
      double d = now() - a;
      if (d < best) best = d;
    }
    if (rep == 1) printf("  decode (%s, %d experts): %.2f GB/s of output\n", threads == 1 ? "1 thread" : "all cores, GCD", nkept, (double)nkept * USED / best / 1e9);
  }
  return bad ? 1 : 0;
}
#endif
