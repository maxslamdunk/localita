// Per-layer read latency, to correlate against per-layer extent fragmentation.
// Reads are interleaved across all 30 layer files so the whole 12.01 GiB corpus
// is the working set (page cache cannot serve it), then attributed per layer.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <time.h>

#define SLOT 3358720L
#define NLAYERS 30
#define NSLOTS 128
#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

int main(int argc, char **argv) {
    const char *dir = argv[1];
    long per = argc > 2 ? atol(argv[2]) : 20;

    int fds[NLAYERS];
    for (int l = 0; l < NLAYERS; l++) {
        char p[1024];
        snprintf(p, sizeof(p), "%s/layer_%02d.bin", dir, l);
        if ((fds[l] = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0) { perror(p); return 1; }
    }
    void *buf;
    if (posix_memalign(&buf, ALIGN, SLOT + ALIGN)) { perror("memalign"); return 1; }

    double sum[NLAYERS]; long cnt[NLAYERS];
    memset(sum, 0, sizeof(sum)); memset(cnt, 0, sizeof(cnt));

    // Round-robin over layers so no layer gets a systematically warmer cache.
    srandom(20260810);
    for (long r = 0; r < per; r++) {
        for (int l = 0; l < NLAYERS; l++) {
            long s = random() % NSLOTS;
            uint64_t t0 = now_ns();
            if (pread(fds[l], buf, SLOT, (off_t)s * SLOT) != SLOT) { perror("pread"); return 1; }
            sum[l] += (double)(now_ns() - t0) / 1000.0;
            cnt[l]++;
        }
    }
    printf("layer  mean_us   GB/s\n");
    for (int l = 0; l < NLAYERS; l++)
        printf("%5d  %7.0f  %5.2f\n", l, sum[l] / cnt[l], (double)SLOT / (sum[l] / cnt[l]) / 1000.0);
    return 0;
}
