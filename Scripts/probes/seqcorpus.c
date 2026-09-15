// Parallel SEQUENTIAL read over the whole 12.01 GiB routed-expert corpus.
//
// Why not seqpar.c on a single file: any file small enough to be convenient is
// also small enough to land in this host's ~1.44 GB page cache, after which
// every later queue depth reads from DRAM and reports 4-7 GB/s. F_NOCACHE does
// not save you -- it stops the kernel caching THIS descriptor's data, but pages
// already resident from an earlier pass still serve the read.
//
// So: treat the 30 layer files as one 12.01 GiB logical stream and give each
// thread a contiguous run of whole files. The working set is ~8x the cache, so
// no ordering of the sweep can be served from memory.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <stdint.h>

#define NLAYERS 30
#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static const char *g_dir;
static int g_nocache;
static long g_bs;

typedef struct {
    int first, last;      // inclusive range of layer indices
    void *buf;
    double bytes;
} Run;

static void *worker(void *arg) {
    Run *r = arg;
    r->bytes = 0;
    for (int l = r->first; l <= r->last; l++) {
        char p[1024];
        snprintf(p, sizeof(p), "%s/layer_%02d.bin", g_dir, l);
        int fd = open(p, O_RDONLY);
        if (fd < 0) { perror(p); exit(1); }
        if (g_nocache) fcntl(fd, F_NOCACHE, 1);
        struct stat st; fstat(fd, &st);
        off_t off = 0;
        while (off < st.st_size) {
            long want = (st.st_size - off) < g_bs ? (long)(st.st_size - off) : g_bs;
            ssize_t got = pread(fd, r->buf, want, off);
            if (got != want) { perror("pread"); exit(1); }
            off += got;
            r->bytes += (double)got;
        }
        close(fd);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <packed_experts_dir> [block_mib] [nocache]\n", argv[0]); return 2; }
    g_dir = argv[1];
    g_bs = (argc > 2 ? atol(argv[2]) : 8) << 20;
    g_nocache = (argc > 3 && atoi(argv[3]) != 0);

    printf(" streams   block_MiB   nocache   GiB      wall_s   GB/s\n");
    for (int k = 1; k <= 8; k *= 2) {
        pthread_t th[8];
        Run r[8];
        int per = NLAYERS / k;
        for (int i = 0; i < k; i++) {
            if (posix_memalign(&r[i].buf, ALIGN, g_bs)) { perror("memalign"); return 1; }
            r[i].first = i * per;
            r[i].last = (i == k - 1) ? NLAYERS - 1 : (i + 1) * per - 1;
        }
        uint64_t t0 = now_ns();
        for (int i = 0; i < k; i++) pthread_create(&th[i], NULL, worker, &r[i]);
        for (int i = 0; i < k; i++) pthread_join(th[i], NULL);
        double wall = (double)(now_ns() - t0) / 1e9;
        double total = 0;
        for (int i = 0; i < k; i++) { total += r[i].bytes; free(r[i].buf); }
        printf("%8d   %9ld   %7s   %6.2f   %6.2f   %4.2f\n", k, g_bs >> 20,
               g_nocache ? "yes" : "no", total / 1073741824.0, wall, total / wall / 1e9);
    }
    return 0;
}
