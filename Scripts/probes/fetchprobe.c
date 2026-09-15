// Routed-expert fetch probe against the REAL installed layer files.
//
// Replicates the production fetch shape from PreadExpertStreamer:
//   - one fd per layer file, O_RDONLY | O_NONBLOCK | O_CLOEXEC
//   - 3,358,720 B preads at slot-aligned offsets into 2 MiB-aligned buffers
//   - serial mode, and a concurrent mode matching executeExpertCachePlan's
//     DispatchQueue.concurrentPerform fan-out over a layer's miss set
//
// Working set is the whole 12.01 GiB routed-expert corpus, so the page cache
// (~1.44 GB on this host) cannot serve it -- the same cold condition the
// 2026-08-10 standalone probe reached at >=4 GiB.
//
// Does NOT load the model, allocate GPU resources, or start any runtime.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <dispatch/dispatch.h>

#define SLOT      3358720L
#define NLAYERS   30
#define NSLOTS    128
#define ALIGN     (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static void report(const char *label, uint64_t *us, long n, double bytes_total, double wall_us) {
    qsort(us, n, sizeof(uint64_t), cmp_u64);
    double sum = 0;
    for (long i = 0; i < n; i++) sum += (double)us[i];
    printf("  %-26s n=%-4ld  mean %6.0f us | p10 %6llu  p50 %6llu  p90 %6llu | min %6llu  max %6llu us\n",
           label, n, sum / n, (unsigned long long)us[n / 10], (unsigned long long)us[n / 2],
           (unsigned long long)us[(n * 9) / 10], (unsigned long long)us[0], (unsigned long long)us[n - 1]);
    printf("  %-26s per-read %.2f GB/s | aggregate over wall %.2f GB/s\n", "",
           (double)SLOT / (sum / n) / 1000.0, bytes_total / wall_us / 1000.0);
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "scratch/gemma4.gturbo/packed_experts";
    long reads = argc > 2 ? atol(argv[2]) : 200;
    unsigned seed = argc > 3 ? (unsigned)atol(argv[3]) : 20260810u;

    int fds[NLAYERS];
    for (int l = 0; l < NLAYERS; l++) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/layer_%02d.bin", dir, l);
        fds[l] = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fds[l] < 0) { perror(path); return 1; }
    }

    // Production uses 16 distinct 2 MiB-aligned slot buffers per layer; a
    // concurrent fan-out writes into distinct buffers, so allocate 8.
    void *bufs[8];
    for (int i = 0; i < 8; i++)
        if (posix_memalign(&bufs[i], ALIGN, SLOT + ALIGN) != 0) { perror("posix_memalign"); return 1; }

    srandom(seed);
    uint64_t *us = malloc(reads * sizeof(uint64_t));

    // ---- Serial: one read at a time, random (layer, slot) across all 30 files.
    uint64_t w0 = now_ns();
    for (long i = 0; i < reads; i++) {
        int l = random() % NLAYERS;
        long s = random() % NSLOTS;
        uint64_t t0 = now_ns();
        ssize_t got = pread(fds[l], bufs[i % 8], SLOT, (off_t)s * SLOT);
        uint64_t t1 = now_ns();
        if (got != SLOT) { fprintf(stderr, "short read %zd (%s)\n", got, strerror(errno)); return 1; }
        us[i] = (t1 - t0) / 1000;
    }
    double wall = (double)(now_ns() - w0) / 1000.0;
    printf("SERIAL  (1 read in flight, 30 fds, %.2f GiB working set)\n", (double)NLAYERS * NSLOTS * SLOT / 1073741824.0);
    report("per-read latency", us, reads, (double)reads * SLOT, wall);

    // ---- Concurrent: batches of k, matching a layer's miss set fanned out by
    // concurrentPerform. k=3 is production's average (77.96 fills/tok / 30).
    for (int k = 2; k <= 8; k += (k == 2 ? 1 : (k == 3 ? 5 : 8))) {
        long batches = reads / k;
        uint64_t *bw = malloc(batches * sizeof(uint64_t));
        int *lay = malloc(8 * sizeof(int));
        long *slo = malloc(8 * sizeof(long));
        int *fdp = fds;
        void **bufp = bufs;
        uint64_t c0 = now_ns();
        for (long b = 0; b < batches; b++) {
            for (int j = 0; j < k; j++) { lay[j] = random() % NLAYERS; slo[j] = random() % NSLOTS; }
            uint64_t t0 = now_ns();
            dispatch_apply(k, DISPATCH_APPLY_AUTO, ^(size_t j) {
                ssize_t got = pread(fdp[lay[j]], bufp[j], SLOT, (off_t)slo[j] * SLOT);
                if (got != SLOT) { fprintf(stderr, "short read in batch\n"); exit(1); }
            });
            bw[b] = (now_ns() - t0) / 1000;
        }
        double cwall = (double)(now_ns() - c0) / 1000.0;
        char lbl[64];
        snprintf(lbl, sizeof(lbl), "batch wall (k=%d)", k);
        printf("CONCURRENT k=%d (%ld batches)\n", k, batches);
        report(lbl, bw, batches, (double)batches * k * SLOT, cwall);
        free(bw); free(lay); free(slo);
    }

    for (int l = 0; l < NLAYERS; l++) close(fds[l]);
    return 0;
}
