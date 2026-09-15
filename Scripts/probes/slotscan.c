// Read every production slot of one file exactly once, in shuffled order.
//
// Why not filelat.c: that picks offsets with replacement, so on a 0.41 GiB file
// against a ~1.44 GB page cache the repeats are served from DRAM and inflate the
// result. Visiting each slot exactly once makes self-caching impossible, so a
// single post-flush pass is honest.
//
// Purpose: the write-order effect (IO-12) was measured with whole-file reads.
// Production issues RANDOM slot-granularity reads. This probe applies the
// production access pattern to the same controls, to test whether the ~1.53x
// ratio is a property of the placement or an artifact of sequential access.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdint.h>
#include <time.h>

#define SLOT 3358720L
#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [seed]\n", argv[0]); return 2; }
    unsigned seed = argc > 2 ? (unsigned)atoi(argv[2]) : 42;

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror(argv[1]); return 1; }
    struct stat st; fstat(fd, &st);
    long nslots = st.st_size / SLOT;

    long *order = malloc((size_t)nslots * sizeof(long));
    for (long i = 0; i < nslots; i++) order[i] = i;
    srandom(seed);
    for (long i = nslots - 1; i > 0; i--) {            // Fisher-Yates
        long j = random() % (i + 1);
        long t = order[i]; order[i] = order[j]; order[j] = t;
    }

    void *buf;
    if (posix_memalign(&buf, ALIGN, SLOT + ALIGN)) { perror("memalign"); return 1; }

    uint64_t t0 = now_ns();
    for (long k = 0; k < nslots; k++) {
        if (pread(fd, buf, SLOT, (off_t)order[k] * SLOT) != SLOT) { perror("pread"); return 1; }
    }
    double sec = (double)(now_ns() - t0) / 1e9;
    close(fd); free(buf); free(order);

    double bytes = (double)nslots * SLOT;
    const char *base = argv[1];
    for (const char *p = argv[1]; *p; p++) if (*p == '/') base = p + 1;
    printf("  %-18s %3ld slots once, shuffled: %.2f GB/s  (%.0f us/slot)\n",
           base, nslots, bytes / sec / 1e9, sec * 1e6 / (double)nslots);
    return 0;
}
