// Random-pread latency over a single file at production slot granularity.
// Reproduces the 2026-08-10 standalone probe: one fd, one 2 MiB-aligned
// reusable buffer, plain O_RDONLY, 3,358,720 B blocks, random slot-aligned
// offsets across the whole file.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>

#define SLOT 3358720L
#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int cmp(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [reads]\n", argv[0]); return 2; }
    long n = argc > 2 ? atol(argv[2]) : 200;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror(argv[1]); return 1; }
    struct stat st; fstat(fd, &st);
    long nslots = st.st_size / SLOT;
    void *buf;
    if (posix_memalign(&buf, ALIGN, SLOT + ALIGN)) { perror("memalign"); return 1; }

    uint64_t *us = malloc(n * sizeof(uint64_t));
    srandom(20260810);
    double sum = 0;
    for (long i = 0; i < n; i++) {
        long s = random() % nslots;
        uint64_t t0 = now_ns();
        if (pread(fd, buf, SLOT, (off_t)s * SLOT) != SLOT) { perror("pread"); return 1; }
        us[i] = (now_ns() - t0) / 1000;
        sum += us[i];
    }
    qsort(us, n, sizeof(uint64_t), cmp);
    printf("  %s: %.2f GiB, %ld slots, n=%ld reads\n", argv[1], (double)st.st_size / 1073741824.0, nslots, n);
    printf("  mean %.0f us | p10 %llu  p50 %llu  p90 %llu | min %llu  max %llu us | %.2f GB/s\n",
           sum / n, (unsigned long long)us[n / 10], (unsigned long long)us[n / 2],
           (unsigned long long)us[(n * 9) / 10], (unsigned long long)us[0],
           (unsigned long long)us[n - 1], (double)SLOT / (sum / n) / 1000.0);
    return 0;
}
