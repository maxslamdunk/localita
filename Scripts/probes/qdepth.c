// Queue-depth sweep with guaranteed thread supply.
//
// The earlier fan-out probe used dispatch_apply, which schedules onto GCD's
// cooperative pool; for BLOCKING work that pool may not supply one thread per
// iteration, so a flat result there does not prove the device is saturated.
// This version spawns k real pthreads, each issuing blocking preads in a loop,
// so k I/Os are genuinely in flight.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

#define SLOT 3358720L
#define NLAYERS 30
#define NSLOTS 128
#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static int fds[NLAYERS];

typedef struct {
    long reads;
    unsigned seed;
    void *buf;
    double sum_us;
    uint64_t maxus, minus;
} Work;

static void *worker(void *arg) {
    Work *w = arg;
    unsigned s = w->seed;
    w->minus = ~0ull; w->maxus = 0; w->sum_us = 0;
    for (long i = 0; i < w->reads; i++) {
        int l = rand_r(&s) % NLAYERS;
        long sl = rand_r(&s) % NSLOTS;
        uint64_t t0 = now_ns();
        if (pread(fds[l], w->buf, SLOT, (off_t)sl * SLOT) != SLOT) { perror("pread"); exit(1); }
        uint64_t d = (now_ns() - t0) / 1000;
        w->sum_us += (double)d;
        if (d < w->minus) w->minus = d;
        if (d > w->maxus) w->maxus = d;
    }
    return NULL;
}

int main(int argc, char **argv) {
    const char *dir = argv[1];
    long per_thread = argc > 2 ? atol(argv[2]) : 40;
    for (int l = 0; l < NLAYERS; l++) {
        char p[1024];
        snprintf(p, sizeof(p), "%s/layer_%02d.bin", dir, l);
        if ((fds[l] = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC)) < 0) { perror(p); return 1; }
    }

    printf(" QD   reads   wall_s   aggregate_GB/s   mean_read_us   min_us   max_us\n");
    for (int k = 1; k <= 16; k *= 2) {
        pthread_t th[16];
        Work w[16];
        for (int i = 0; i < k; i++) {
            if (posix_memalign(&w[i].buf, ALIGN, SLOT + ALIGN)) { perror("memalign"); return 1; }
            w[i].reads = per_thread;
            w[i].seed = 20260810u + (unsigned)(k * 1000 + i);
        }
        uint64_t t0 = now_ns();
        for (int i = 0; i < k; i++) pthread_create(&th[i], NULL, worker, &w[i]);
        for (int i = 0; i < k; i++) pthread_join(th[i], NULL);
        double wall_s = (double)(now_ns() - t0) / 1e9;

        double sum = 0; uint64_t mn = ~0ull, mx = 0;
        for (int i = 0; i < k; i++) {
            sum += w[i].sum_us;
            if (w[i].minus < mn) mn = w[i].minus;
            if (w[i].maxus > mx) mx = w[i].maxus;
            free(w[i].buf);
        }
        long total = (long)k * per_thread;
        printf("%3d   %5ld   %6.2f   %14.2f   %12.0f   %6llu   %6llu\n",
               k, total, wall_s, (double)total * SLOT / wall_s / 1e9, sum / total,
               (unsigned long long)mn, (unsigned long long)mx);
    }
    return 0;
}
