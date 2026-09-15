// What can the installed layer files actually deliver?
//   (a) sequential read in file order, 3,358,720 B blocks  -> best-case locality
//   (b) random reads at 1x, 2x, 4x the production slot size -> does coalescing pay?
// Working set spans multiple layer files so the page cache cannot serve it.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <time.h>

#define SLOT 3358720L
#define NLAYERS 30
#define FSIZE 429916160L
#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

int main(int argc, char **argv) {
    const char *dir = argv[1];
    int fds[NLAYERS];
    for (int l = 0; l < NLAYERS; l++) {
        char p[1024];
        snprintf(p, sizeof(p), "%s/layer_%02d.bin", dir, l);
        if ((fds[l] = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0) { perror(p); return 1; }
    }
    void *buf;
    if (posix_memalign(&buf, ALIGN, 16L << 20)) { perror("memalign"); return 1; }

    // (a) Sequential, in file order, across 14 layer files (~5.6 GiB).
    long nfiles = 14, blocks = FSIZE / SLOT;
    uint64_t t0 = now_ns();
    long bytes = 0;
    for (long f = 0; f < nfiles; f++)
        for (long b = 0; b < blocks; b++) {
            if (pread(fds[f], buf, SLOT, (off_t)b * SLOT) != SLOT) { perror("pread"); return 1; }
            bytes += SLOT;
        }
    double s = (double)(now_ns() - t0) / 1e9;
    printf("SEQUENTIAL  %ld files x %ld blocks of %ld B: %.2f GiB in %.2f s = %.2f GB/s (%.0f us/block)\n",
           nfiles, blocks, SLOT, (double)bytes / 1073741824.0, s,
           (double)bytes / s / 1e9, s * 1e6 / (double)(nfiles * blocks));

    // (b) Random at multiples of the slot size.
    srandom(20260810);
    for (int mult = 1; mult <= 4; mult *= 2) {
        long sz = SLOT * mult, n = 120;
        long maxslot = FSIZE / sz;
        uint64_t r0 = now_ns();
        for (long i = 0; i < n; i++) {
            int l = random() % NLAYERS;
            long o = (random() % maxslot) * sz;
            if (pread(fds[l], buf, sz, o) != sz) { perror("pread"); return 1; }
        }
        double rs = (double)(now_ns() - r0) / 1e9;
        printf("RANDOM %dx slot (%7ld B): %ld reads in %.2f s = %.2f GB/s (%.0f us/read)\n",
               mult, sz, n, rs, (double)n * sz / rs / 1e9, rs * 1e6 / n);
    }
    return 0;
}
