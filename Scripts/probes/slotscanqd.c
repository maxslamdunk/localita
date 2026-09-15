// slotscan.c at a chosen queue depth: does the write-order win STACK with the
// queue-depth win, or are they the same headroom counted twice?
//
// The shuffled slot order is partitioned across T pthreads, so every slot is
// still read exactly once and no read can be served from the page cache by an
// earlier read in the same pass. Real pthreads, not dispatch_apply -- GCD may
// not supply threads for blocking work (METH/IO-11).
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <stdint.h>
#include <time.h>

#define SLOT 3358720L
#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

typedef struct { int fd; long *order; long lo, hi; } Job;

static void *worker(void *arg) {
    Job *j = (Job *)arg;
    void *buf;
    if (posix_memalign(&buf, ALIGN, SLOT + ALIGN)) return NULL;
    for (long k = j->lo; k < j->hi; k++)
        if (pread(j->fd, buf, SLOT, (off_t)j->order[k] * SLOT) != SLOT) { perror("pread"); break; }
    free(buf);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [threads] [seed]\n", argv[0]); return 2; }
    int nthreads = argc > 2 ? atoi(argv[2]) : 1;
    unsigned seed = argc > 3 ? (unsigned)atoi(argv[3]) : 42;

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror(argv[1]); return 1; }
    struct stat st; fstat(fd, &st);
    long nslots = st.st_size / SLOT;

    long *order = malloc((size_t)nslots * sizeof(long));
    for (long i = 0; i < nslots; i++) order[i] = i;
    srandom(seed);
    for (long i = nslots - 1; i > 0; i--) {
        long j = random() % (i + 1);
        long t = order[i]; order[i] = order[j]; order[j] = t;
    }

    pthread_t *th = malloc((size_t)nthreads * sizeof(pthread_t));
    Job *jobs = malloc((size_t)nthreads * sizeof(Job));
    uint64_t t0 = now_ns();
    for (int t = 0; t < nthreads; t++) {
        jobs[t] = (Job){ fd, order, nslots * t / nthreads, nslots * (t + 1) / nthreads };
        pthread_create(&th[t], NULL, worker, &jobs[t]);
    }
    for (int t = 0; t < nthreads; t++) pthread_join(th[t], NULL);
    double sec = (double)(now_ns() - t0) / 1e9;
    close(fd);

    const char *base = argv[1];
    for (const char *p = argv[1]; *p; p++) if (*p == '/') base = p + 1;
    printf("  %-18s QD%-2d %.2f GB/s\n", base, nthreads, (double)nslots * SLOT / sec / 1e9);
    return 0;
}
