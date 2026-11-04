// replay: the decode's expert reads on real storage, raw against compressed.
//
// Replays a read schedule (schedule.py) layer by layer, with no model:
//   io phase: the layer's foreground reads, fanned out with dispatch_apply
//             like executeExpertCachePlan, plus the wait for the early read
//             issued during the previous gap;
//   gap:      the layer's GPU work, as an idle sleep; the early read for the
//             next layer is issued at its start, as NextLayerExpertPrefetcher
//             does.
// raw arm:  one pread of 3,358,720 B per expert into a slot buffer.
// comp arm: the expert's excodec record read in --pieces sequential preads;
//           each piece's chunks are decoded into the slot buffer on the
//           global concurrent queue as soon as the piece lands. The io phase
//           ends when every decode has finished.
// Every fd has F_NOCACHE. Four physical layers stand in for all 30 (trace
// layer l uses physical layer LAYERS[l % 4]), which keeps the compressed
// copy at 1.5 GB on this nearly full disk.
//
//   cc -O3 -DNSTREAMS=8 -I../codec -o replay replay.c
//   replay build <packed_experts> <out.bin>
//   replay run <packed_experts> <out.bin> <schedule> [--tokens N] [--gap-us G]
//          [--pieces R] [--order ABBA]

#define EXCODEC_NO_MAIN
#include "excodec.c"

#include <sys/mman.h>
#include <sys/stat.h>

static const int LAYERS[4] = {0, 1, 2, 3};
#define NPHYS 4
#define REC_HDR 128 /* 25 u32 chunk offsets, relative to the record start */
#define NSLOTS 48

typedef struct { uint64_t off; uint32_t len; uint32_t chunk[NCHUNKS + 1]; } Rec;
typedef struct { Tables tables[NPHYS]; Rec rec[NPHYS][NEXPERTS]; } Index;

static int open_nocache(const char *path, int flags) {
  int fd = open(path, flags, 0644);
  if (fd < 0) { perror(path); exit(1); }
  fcntl(fd, F_NOCACHE, 1);
  return fd;
}

static void *aligned(size_t n) { void *p; if (posix_memalign(&p, 16384, n)) exit(1); memset(p, 0, n); return p; }

static double resident_fraction(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  struct stat st; fstat(fd, &st);
  void *m = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
  size_t pages = (st.st_size + 16383) / 16384;
  char *v = malloc(pages);
  mincore(m, st.st_size, v);
  size_t r = 0;
  for (size_t i = 0; i < pages; i++) r += v[i] & 1;
  munmap(m, st.st_size); close(fd); free(v);
  return (double)r / pages;
}

static void layer_path(char *buf, size_t n, const char *dir, int phys) { snprintf(buf, n, "%s/layer_%02d.bin", dir, phys); }

static int build(const char *dir, const char *out, uint32_t align) {
  Index *ix = calloc(1, sizeof(Index));
  uint8_t *raw = aligned(STRIDE), *chk = aligned(STRIDE);
  uint8_t *rec = aligned(STRIDE + 65536);
  char path[1024], ipath[1100];
  snprintf(ipath, sizeof ipath, "%s.idx", out);
  int ofd = open_nocache(out, O_WRONLY | O_CREAT | O_TRUNC);
  uint64_t pos = 0;
  size_t stats[4] = {0};
  for (int i = 0; i < NPHYS; i++) {
    layer_path(path, sizeof path, dir, LAYERS[i]);
    int fd = open_nocache(path, O_RDONLY);
    Counts *c = calloc(1, sizeof(Counts));
    for (int e = 0; e < NEXPERTS; e += 4) {
      if (pread(fd, raw, STRIDE, (off_t)e * STRIDE) != STRIDE) return 1;
      count_expert(c, raw);
    }
    build_tables(&ix->tables[i], c);
    free(c);
    for (int e = 0; e < NEXPERTS; e++) {
      if (pread(fd, raw, STRIDE, (off_t)e * STRIDE) != STRIDE) return 1;
      Rec *r = &ix->rec[i][e];
      uint32_t o = REC_HDR;
      for (int k = 0; k < NCHUNKS; k++) {
        r->chunk[k] = o;
        o += (uint32_t)encode_chunk(&ix->tables[i], k / CHUNKS_PER_KIND, raw, (uint32_t)(k % CHUNKS_PER_KIND) * CHUNK_GROUPS, rec + o, stats);
      }
      r->chunk[NCHUNKS] = o;
      memcpy(rec, r->chunk, sizeof r->chunk);
      for (int k = 0; k < NCHUNKS; k++)
        DECODE(&ix->tables[i], k / CHUNKS_PER_KIND, rec + r->chunk[k], chk, (uint32_t)(k % CHUNKS_PER_KIND) * CHUNK_GROUPS);
      if (memcmp(chk, raw, USED)) { fprintf(stderr, "round trip failed, layer %d expert %d\n", LAYERS[i], e); return 1; }
      uint32_t padded = (o + align - 1) / align * align;
      memset(rec + o, 0, padded - o);
      r->off = pos; r->len = o;
      if (pwrite(ofd, rec, padded, (off_t)pos) != (ssize_t)padded) { perror("pwrite"); return 1; }
      pos += padded;
    }
    close(fd);
    fprintf(stderr, "layer %d encoded\n", LAYERS[i]);
  }
  close(ofd);
  FILE *f = fopen(ipath, "wb");
  fwrite(ix, sizeof(Index), 1, f);
  fclose(f);
  printf("built %s: %.1f MB for %d experts (%.4f of raw, %u B-aligned records), every expert round-tripped\n",
         out, pos / 1e6, NPHYS * NEXPERTS, (double)pos / ((double)NPHYS * NEXPERTS * STRIDE), align);
  return 0;
}

// A fresh raw copy of the four layers, written the same way as the compressed
// file, so file placement is the same for both arms.
static int rawcopy(const char *dir, const char *out) {
  uint8_t *raw = aligned(STRIDE);
  char path[1024];
  int ofd = open_nocache(out, O_WRONLY | O_CREAT | O_TRUNC);
  for (int i = 0; i < NPHYS; i++) {
    layer_path(path, sizeof path, dir, LAYERS[i]);
    int fd = open_nocache(path, O_RDONLY);
    for (int e = 0; e < NEXPERTS; e++) {
      if (pread(fd, raw, STRIDE, (off_t)e * STRIDE) != STRIDE) return 1;
      if (pwrite(ofd, raw, STRIDE, ((off_t)i * NEXPERTS + e) * STRIDE) != STRIDE) { perror("pwrite"); return 1; }
    }
    close(fd);
  }
  close(ofd);
  printf("raw copy %s written\n", out);
  return 0;
}


// ---------- side-only variant: codes raw, scales and biases compressed ----------
// Record: [codes of gate, up, down, raw: 2,973,696 B][side block]. Side block:
// u32 off[NKINDS][SSTREAMS + 1] | lo bytes per kind | bitstreams; stream s of
// kind k holds groups [s ng / SSTREAMS, (s + 1) ng / SSTREAMS) as (scale-high,
// bias) symbol pairs, an escape followed by the raw 16 bits.
#define SSTREAMS 8
#define CODES_BYTES 2973696
#define SIDE_HDR (4 * NKINDS * (SSTREAMS + 1))

static uint32_t kind_groups(int k) { return KINDS[k].rows * KINDS[k].groups_per_row; }

static size_t side_encode(const Tables *t, const uint8_t *e, uint8_t *out) {
  uint32_t *off = (uint32_t *)out;
  size_t pos = SIDE_HDR;
  uint8_t *lo = out + pos;
  for (int k = 0; k < NKINDS; k++) {
    const uint16_t *sc = (const uint16_t *)(e + KINDS[k].scales);
    for (uint32_t g = 0; g < kind_groups(k); g++) *lo++ = sc[g] & 0xFF;
  }
  pos = (size_t)(lo - out);
  for (int k = 0; k < NKINDS; k++) {
    const uint16_t *sc = (const uint16_t *)(e + KINDS[k].scales), *bi = (const uint16_t *)(e + KINDS[k].biases);
    uint32_t ng = kind_groups(k);
    for (int st = 0; st < SSTREAMS; st++) {
      off[k * (SSTREAMS + 1) + st] = (uint32_t)pos;
      BW w = {out + pos, 1 << 20, 0, 0, 0};
      for (uint32_t g = st * ng / SSTREAMS; g < (st + 1) * ng / SSTREAMS; g++) {
        bw_put(&w, t->shi[k].code[sc[g] >> 8], t->shi[k].len[sc[g] >> 8]);
        int z, bs = bias_symbol(sc[g], bi[g], &z);
        bw_put(&w, t->bias[k].code[bs], t->bias[k].len[bs]);
        if (bs == ESC) bw_put(&w, bi[g], 16);
      }
      bw_flush(&w);
      pos += w.pos;
    }
    off[k * (SSTREAMS + 1) + SSTREAMS] = (uint32_t)pos;
  }
  memset(out + pos, 0, 16);
  return pos;
}

static void side_decode_kind(const Tables *t, int k, const uint8_t *in, uint8_t *e) {
  const uint32_t *off = (const uint32_t *)in + k * (SSTREAMS + 1);
  const uint8_t *lo = in + SIDE_HDR;
  for (int j = 0; j < k; j++) lo += kind_groups(j);
  uint16_t *sc = (uint16_t *)(e + KINDS[k].scales), *bi = (uint16_t *)(e + KINDS[k].biases);
  uint32_t ng = kind_groups(k), per = ng / SSTREAMS;
  const uint16_t *SHL = t->shi[k].lut, *BSL = t->bias[k].lut;
  static const uint8_t ZOF[NBIAS] = {0,0,0,1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6,7,7,7,8,8,8,9,9,9,10,10,10,11,11,11,12,12,12,13,13,13,14,14,14,15,15,15,0};
  // pass 1: eight streams in registers, two symbols per window, symbols to
  // arrays; pass 2: rebuild scales and biases in a loop the compiler vectorizes.
  // Escapes never occur in this model (0 of 3,840 experts); the rare path
  // patches them after pass 2.
  static __thread uint8_t HI[30976], BSY[30976];
  static __thread uint32_t escg[64]; static __thread uint16_t escv[64];
  int nesc = 0;
#define SD8(X) X(0) X(1) X(2) X(3) X(4) X(5) X(6) X(7)
#define SDECL(q) const uint8_t *b##q##_ = in + off[q]; uint64_t p##q = 0, w##q;
  SD8(SDECL)
  for (uint32_t i = 0; i < per; i++) {
#define SSTEP(q) { \
      w##q = load_be64(b##q##_ + (p##q >> 3)) << (p##q & 7); \
      uint16_t e1 = SHL[w##q >> (64 - LIMIT)]; unsigned l1 = e1 >> 8; w##q <<= l1; \
      uint16_t e2 = BSL[w##q >> (64 - LIMIT)]; unsigned l2 = e2 >> 8; p##q += l1 + l2; \
      uint32_t g = q * per + i; HI[g] = (uint8_t)e1; BSY[g] = (uint8_t)e2; \
      if (__builtin_expect((e2 & 0xFF) == ESC, 0)) { escg[nesc] = g; escv[nesc++] = (uint16_t)((load_be64(b##q##_ + (p##q >> 3)) << (p##q & 7)) >> 48); p##q += 16; } }
    SD8(SSTEP)
  }
  static const float NEGZ[NBIAS] = {
    -0.f,-0.f,-0.f,-1,-1,-1,-2,-2,-2,-3,-3,-3,-4,-4,-4,-5,-5,-5,-6,-6,-6,-7,-7,-7,-8,-8,-8,-9,-9,-9,
    -10,-10,-10,-11,-11,-11,-12,-12,-12,-13,-13,-13,-14,-14,-14,-15,-15,-15,0};
  static const int8_t RES[NBIAS] = {-1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,
    -1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,-1,0,1,0};
  for (uint32_t g = 0; g < ng; g++) {
    uint16_t sv = (uint16_t)((HI[g] << 8) | lo[g]);
    sc[g] = sv;
    float prod = NEGZ[BSY[g]] * bf2f(sv);
    uint32_t u; memcpy(&u, &prod, 4);
    uint16_t pred = (uint16_t)((u + 0x7FFF + ((u >> 16) & 1)) >> 16);
    pred = BSY[g] < 3 ? 0 : pred; // z = 0 predicts exactly 0
    bi[g] = (uint16_t)(pred + RES[BSY[g]]);
  }
  for (int x = 0; x < nesc; x++) bi[escg[x]] = escv[x];
}

static void side_decode(const Tables *t, const uint8_t *in, uint8_t *e) {
  for (int k = 0; k < NKINDS; k++) side_decode_kind(t, k, in, e);
}


typedef struct { int token, layer, early, n, e[8]; } Step;

static Step *load_schedule(const char *path, int *nsteps, int max_tokens) {
  FILE *f = fopen(path, "r");
  if (!f) { perror(path); exit(1); }
  int cap = 65536, n = 0, first = -1;
  Step *s = malloc(cap * sizeof(Step));
  Step x;
  while (fscanf(f, "%d %d %d %d", &x.token, &x.layer, &x.early, &x.n) == 4) {
    for (int i = 0; i < x.n; i++) if (fscanf(f, "%d", &x.e[i]) != 1) exit(1);
    if (first < 0) first = x.token;
    if (x.token - first >= max_tokens) break;
    s[n++] = x;
  }
  fclose(f);
  *nsteps = n;
  return s;
}

typedef struct {
  const char *dir; int raw_fd[NPHYS], comp_fd;
  Index *ix; uint8_t *slot[NSLOTS], *stage[NSLOTS];
  int pieces, gap_us, no_decode, conc, raw_pieces, serial_tail, raw_serial;
  off_t raw_base[NPHYS];
  uint8_t *mem; /* --emulate: every compressed record in RAM, read lengths come from the raw files */
  int side; uint8_t *side_mem[NPHYS][NEXPERTS]; uint32_t side_len[NPHYS][NEXPERTS];
} Ctx;

static void sleep_us(int us) { struct timespec ts = {us / 1000000, (long)(us % 1000000) * 1000}; nanosleep(&ts, NULL); }

static void read_range(Ctx *c, int phys, int e, int sidx, int k0, int k1, dispatch_group_t g, dispatch_queue_t dq) {
  Rec *r = &c->ix->rec[phys][e];
  uint8_t *st = c->stage[sidx], *sl = c->slot[sidx];
  const Tables *t = &c->ix->tables[phys];
  uint32_t a = k0 == 0 ? 0 : r->chunk[k0], b = r->chunk[k1];
  uint32_t a4 = a / 4096 * 4096, b4 = (b + 4095) / 4096 * 4096;
  if (c->mem) {
    // same byte count, at the expert's own place in the installed layer file
    if (pread(c->raw_fd[phys], st + a4, b4 - a4, c->raw_base[phys] + (off_t)e * STRIDE + a4) != (ssize_t)(b4 - a4)) { perror("pread emu"); exit(1); }
  } else if (pread(c->comp_fd, st + a4, b4 - a4, (off_t)(r->off + a4)) != (ssize_t)(b4 - a4)) { perror("pread comp"); exit(1); }
  const uint8_t *src = c->mem ? c->mem + r->off : st;
  for (int k = k0; k < k1 && !c->no_decode; k++) {
    uint32_t co = r->chunk[k];
    dispatch_group_async(g, dq, ^{
      DECODE(t, k / CHUNKS_PER_KIND, src + co, sl, (uint32_t)(k % CHUNKS_PER_KIND) * CHUNK_GROUPS);
    });
  }
}

static void read_piece(Ctx *c, int phys, int e, int sidx, int p, int pieces, dispatch_group_t g, dispatch_queue_t dq) {
  read_range(c, phys, e, sidx, p * NCHUNKS / pieces, (p + 1) * NCHUNKS / pieces, g, dq);
}

static void read_comp(Ctx *c, int phys, int e, int sidx, dispatch_group_t g, dispatch_queue_t dq, int pieces) {
  for (int p = 0; p < pieces; p++) read_piece(c, phys, e, sidx, p, pieces, g, dq);
}

static void read_side(Ctx *c, int phys, int e, int sidx, dispatch_group_t g, dispatch_queue_t dq) {
  uint32_t len = (CODES_BYTES + c->side_len[phys][e] + 4095) / 4096 * 4096;
  if (pread(c->raw_fd[phys], c->stage[sidx], len, c->raw_base[phys] + (off_t)e * STRIDE) != (ssize_t)len) { perror("pread side"); exit(1); }
  if (c->no_decode) return;
  const Tables *t = &c->ix->tables[phys];
  const uint8_t *blk = c->side_mem[phys][e];
  uint8_t *sl = c->slot[sidx];
  for (int k = 0; k < NKINDS; k++) dispatch_group_async(g, dq, ^{ side_decode_kind(t, k, blk, sl); });
}

// returns io seconds summed over layers
static double run_arm(Ctx *c, Step *s, int n, int comp, double *wall) {
  dispatch_queue_t fan = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_queue_t dq = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  dispatch_queue_t eq = dispatch_queue_create("early", DISPATCH_QUEUE_SERIAL);
  dispatch_group_t eg = dispatch_group_create();
  double io = 0, w0 = now();
  int next_slot = 0;
  for (int i = 0; i < n; i++) {
    Step *st = &s[i];
    int phys = st->layer % NPHYS;
    double t0 = now();
    int base = next_slot; next_slot = (next_slot + 8) % (NSLOTS - 8);
    if (comp) {
      dispatch_group_t g = dispatch_group_create();
      if (c->side) {
        dispatch_apply((size_t)st->n, fan, ^(size_t j) { read_side(c, phys, st->e[j], base + (int)j, g, dq); });
      } else if (c->serial_tail) {
        // experts whole and one after another, each decoded while the next
        // reads; the layer's last expert in shrinking pieces: rest, 3, 1 chunks
        for (int j = 0; j < st->n; j++) {
          if (j + 1 < st->n || c->serial_tail == 2) { read_range(c, phys, st->e[j], base + j, 0, NCHUNKS, g, dq); continue; }
          read_range(c, phys, st->e[j], base + j, 0, NCHUNKS - 4, g, dq);
          read_range(c, phys, st->e[j], base + j, NCHUNKS - 4, NCHUNKS - 1, g, dq);
          read_range(c, phys, st->e[j], base + j, NCHUNKS - 1, NCHUNKS, g, dq);
        }
      } else if (c->conc) {
        int P = c->pieces;
        dispatch_apply((size_t)st->n * P, fan, ^(size_t j) { read_piece(c, phys, st->e[j / P], base + (int)(j / P), (int)(j % P), P, g, dq); });
      } else
        dispatch_apply((size_t)st->n, fan, ^(size_t j) { read_comp(c, phys, st->e[j], base + (int)j, g, dq, c->pieces); });
      dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    } else {
      int P = c->raw_pieces;
      if (c->raw_serial)
        for (int j = 0; j < st->n; j++) {
          if (pread(c->raw_fd[phys], c->slot[base + j], STRIDE, c->raw_base[phys] + (off_t)st->e[j] * STRIDE) != STRIDE) { perror("pread raw"); exit(1); }
        }
      else dispatch_apply((size_t)st->n * P, fan, ^(size_t j) {
        size_t x = j / P, p = j % P;
        size_t a = STRIDE / 16384 * p / P * 16384, b = p + 1 == (size_t)P ? STRIDE : STRIDE / 16384 * (p + 1) / P * 16384;
        if (pread(c->raw_fd[phys], c->slot[base + x] + a, b - a, c->raw_base[phys] + (off_t)st->e[x] * STRIDE + a) != (ssize_t)(b - a)) { perror("pread raw"); exit(1); }
      });
    }
    dispatch_group_wait(eg, DISPATCH_TIME_FOREVER); // the early read for this layer
    io += now() - t0;
    if (st->early >= 0 && st->layer + 1 < NLAYERS) {
      int ephys = (st->layer + 1) % NPHYS, ee = st->early, es = NSLOTS - 1;
      dispatch_group_async(eg, eq, ^{
        if (comp && c->side) read_side(c, ephys, ee, es, eg, dq);
        else if (comp) read_comp(c, ephys, ee, es, eg, dq, 1);
        else if (pread(c->raw_fd[ephys], c->slot[es], STRIDE, c->raw_base[ephys] + (off_t)ee * STRIDE) != STRIDE) { perror("pread early"); exit(1); }
      });
    }
    sleep_us(c->gap_us);
  }
  dispatch_group_wait(eg, DISPATCH_TIME_FOREVER);
  *wall = now() - w0;
  return io;
}


static int side_bench(const char *dir, const char *comp_path) {
  char ipath[1100], path[1024];
  snprintf(ipath, sizeof ipath, "%s.idx", comp_path);
  Index *ix = malloc(sizeof(Index));
  FILE *f = fopen(ipath, "rb");
  if (!f || fread(ix, sizeof(Index), 1, f) != 1) return 1;
  fclose(f);
  uint8_t *raw = aligned(STRIDE), *chk = aligned(STRIDE), *blk = aligned(1 << 20);
  size_t total = 0, total_aligned = 0, bad = 0, n = 0;
  double dec = 0;
  for (int i = 0; i < NPHYS; i++) {
    layer_path(path, sizeof path, dir, LAYERS[i]);
    int fd = open_nocache(path, O_RDONLY);
    for (int e = 1; e < NEXPERTS; e += 2, n++) {
      if (pread(fd, raw, STRIDE, (off_t)e * STRIDE) != STRIDE) return 1;
      size_t len = side_encode(&ix->tables[i], raw, blk);
      size_t rec = CODES_BYTES + len;
      total += rec; total_aligned += (rec + 4095) / 4096 * 4096;
      memcpy(chk, raw, STRIDE);
      for (int k = 0; k < NKINDS; k++) {
        memset(chk + KINDS[k].scales, 0, kind_groups(k) * 2);
        memset(chk + KINDS[k].biases, 0, kind_groups(k) * 2);
      }
      double best = 1e9;
      for (int rep = 0; rep < 5; rep++) { double a = now(); side_decode(&ix->tables[i], blk, chk); double d = now() - a; if (d < best) best = d; }
      dec += best;
      if (memcmp(chk, raw, USED)) bad++;
    }
    close(fd);
  }
  printf("side-only: %zu odd experts of layers 0-3, record %.4f of raw (%+.2f%%), 4 KiB-aligned %.4f (%+.2f%%); round trip %s\n",
         n, (double)total / (n * (double)STRIDE), ((double)total / (n * (double)STRIDE) - 1) * 100,
         (double)total_aligned / (n * (double)STRIDE), ((double)total_aligned / (n * (double)STRIDE) - 1) * 100, bad ? "FAILED" : "bit-exact");
  printf("side decode, one M1 P-core thread: %.1f us per expert (all three kinds)\n", dec / n * 1e6);
  return bad ? 1 : 0;
}

int main(int argc, char **argv) {
  if (argc >= 4 && !strcmp(argv[1], "build")) return build(argv[2], argv[3], argc >= 5 ? (uint32_t)atoi(argv[4]) : 4096);
  if (argc >= 4 && !strcmp(argv[1], "rawcopy")) return rawcopy(argv[2], argv[3]);
  if (argc >= 4 && !strcmp(argv[1], "side-bench")) return side_bench(argv[2], argv[3]);
  if (argc < 5 || strcmp(argv[1], "run")) {
    fprintf(stderr, "usage: replay build <packed_experts> <out.bin> | run <packed_experts> <out.bin> <schedule> [--tokens N] [--gap-us G] [--pieces R] [--order ABBA]\n");
    return 2;
  }
  Ctx c = {.dir = argv[2], .pieces = 6, .gap_us = 2700, .raw_pieces = 1};
  int tokens = 128;
  const char *order = "ABBA";
  const char *raw_copy = NULL;
  int emulate = 0;
  for (int i = 5; i < argc; i++) {
    if (!strcmp(argv[i], "--tokens")) tokens = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--gap-us")) c.gap_us = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--pieces")) c.pieces = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--order")) order = argv[++i];
    else if (!strcmp(argv[i], "--no-decode")) c.no_decode = 1;
    else if (!strcmp(argv[i], "--raw-copy")) raw_copy = argv[++i];
    else if (!strcmp(argv[i], "--emulate")) emulate = 1;
    else if (!strcmp(argv[i], "--concurrent-pieces")) c.conc = 1;
    else if (!strcmp(argv[i], "--serial-tail")) c.serial_tail = 1;
    else if (!strcmp(argv[i], "--serial-whole")) c.serial_tail = 2;
    else if (!strcmp(argv[i], "--raw-serial")) c.raw_serial = 1;
    else if (!strcmp(argv[i], "--side")) c.side = 1;
    else if (!strcmp(argv[i], "--raw-pieces")) c.raw_pieces = atoi(argv[++i]);
  }
  char ipath[1100], path[1024];
  snprintf(ipath, sizeof ipath, "%s.idx", argv[3]);
  c.ix = malloc(sizeof(Index));
  FILE *f = fopen(ipath, "rb");
  if (!f || fread(c.ix, sizeof(Index), 1, f) != 1) { fprintf(stderr, "missing %s; run build first\n", ipath); return 1; }
  fclose(f);
  for (int i = 0; i < NPHYS; i++) {
    layer_path(path, sizeof path, c.dir, LAYERS[i]);
    printf("resident in page cache: %s %.1f%%\n", path, 100 * resident_fraction(path));
    c.raw_fd[i] = open_nocache(path, O_RDONLY);
  }
  if (raw_copy) {
    printf("raw arm reads the fresh copy %s (resident %.1f%%)\n", raw_copy, 100 * resident_fraction(raw_copy));
    int fd = open_nocache(raw_copy, O_RDONLY);
    for (int i = 0; i < NPHYS; i++) { c.raw_fd[i] = fd; c.raw_base[i] = (off_t)i * NEXPERTS * STRIDE; }
  }
  printf("resident in page cache: %s %.1f%%\n", argv[3], 100 * resident_fraction(argv[3]));
  c.comp_fd = open_nocache(argv[3], O_RDONLY);
  if (emulate) {
    struct stat stt; fstat(c.comp_fd, &stt);
    c.mem = aligned((size_t)stt.st_size + 65536);
    if (pread(c.comp_fd, c.mem, (size_t)stt.st_size, 0) != stt.st_size) { perror("load comp"); return 1; }
    printf("emulating: compressed records in RAM (%.1f MB); the comp arm reads their lengths from the installed layer files\n", stt.st_size / 1e6);
  }
  for (int i = 0; i < NSLOTS; i++) { c.slot[i] = aligned(STRIDE); c.stage[i] = aligned(STRIDE + 65536); }
  if (c.side) {
    if (!emulate) { fprintf(stderr, "--side needs --emulate\n"); return 2; }
    uint8_t *raw = aligned(STRIDE), *blk = aligned(1 << 20);
    size_t tot = 0;
    for (int i = 0; i < NPHYS; i++)
      for (int e = 0; e < NEXPERTS; e++) {
        if (pread(c.raw_fd[i], raw, STRIDE, c.raw_base[i] + (off_t)e * STRIDE) != STRIDE) return 1;
        size_t len = side_encode(&c.ix->tables[i], raw, blk);
        c.side_mem[i][e] = malloc(len + 16); memcpy(c.side_mem[i][e], blk, len + 16);
        c.side_len[i][e] = (uint32_t)len; tot += (CODES_BYTES + len + 4095) / 4096 * 4096;
      }
    printf("side-only arm: codes raw, scales and biases compressed; records %.4f of raw\n", (double)tot / (NPHYS * NEXPERTS * (double)STRIDE));
  }
  int n;
  Step *s = load_schedule(argv[4], &n, tokens);
  int fg = 0, early = 0;
  for (int i = 0; i < n; i++) { fg += s[i].n; early += s[i].early >= 0; }
  printf("schedule: %d tokens, %.2f foreground + %.2f early reads per token; gap %d us per layer; comp pieces %d%s%s; raw pieces %d%s\n",
         n / NLAYERS, (double)fg * NLAYERS / n, (double)early * NLAYERS / n, c.gap_us, c.pieces, c.serial_tail == 2 ? " (ignored: serial, whole experts)" : c.serial_tail ? " (ignored: serial, last expert split rest/3/1 chunks)" : c.conc ? " (concurrent)" : " (sequential)", c.no_decode ? ", decode skipped" : "", c.raw_pieces, c.raw_serial ? ", raw reads serial" : ", raw reads fanned out");
  double sum_io[2] = {0}, sum_wall[2] = {0}; int cnt[2] = {0};
  for (const char *o = order; *o; o++) {
    int comp = *o == 'B';
    double wall, io = run_arm(&c, s, n, comp, &wall);
    double per_tok = io / (n / NLAYERS) * 1e3;
    printf("  %c (%s): io %.2f ms/token, wall %.2f ms/token\n", *o, comp ? "compressed" : "raw", per_tok, wall / (n / NLAYERS) * 1e3);
    fflush(stdout);
    sum_io[comp] += per_tok; sum_wall[comp] += wall / (n / NLAYERS) * 1e3; cnt[comp]++;
  }
  if (cnt[0] && cnt[1]) {
    double a = sum_io[0] / cnt[0], b = sum_io[1] / cnt[1];
    printf("mean io: raw %.2f, compressed %.2f ms/token (%+.1f%%); wall %+.1f%%\n", a, b, (b / a - 1) * 100,
           (sum_wall[1] / cnt[1] / (sum_wall[0] / cnt[0]) - 1) * 100);
  }
  return 0;
}
