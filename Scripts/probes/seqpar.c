// Parallel SEQUENTIAL read: the measurement seqfile.c could not make.
//
// seqfile.c is a single-threaded blocking pread loop, i.e. QD1 with only kernel
// readahead for overlap. Peak-throughput benchmarks (Blackmagic and friends)
// use several streams at once, which is why they report numbers a QD1 loop
// cannot reach. This probe splits one file into k contiguous stripes and gives
// each stripe its own pthread, so k sequential streams are genuinely in flight.
//
// Run it against a file larger than the ~1.44 GB page cache, or pass2-style
// warm hits will be reported as device throughput.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <stdint.h>

#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

typedef struct {
    int fd;
    off_t start, end;
    long bs;
    void *buf;
} Stripe;

static void *worker(void *arg) {
    Stripe *s = arg;
    off_t off = s->start;
    while (off < s->end) {
        long want = (s->end - off) < s->bs ? (long)(s->end - off) : s->bs;
        ssize_t got = pread(s->fd, s->buf, want, off);
        if (got != want) { perror("pread"); exit(1); }
        off += got;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [block_mib] [nocache]\n", argv[0]); return 2; }
    long bs = (argc > 2 ? atol(argv[2]) : 8) << 20;
    int nocache = (argc > 3 && atoi(argv[3]) != 0);

    printf(" QD   block_MiB   nocache   wall_s   GB/s\n");
    for (int k = 1; k <= 8; k *= 2) {
        int fd = open(argv[1], O_RDONLY);
        if (fd < 0) { perror(argv[1]); return 1; }
        if (nocache && fcntl(fd, F_NOCACHE, 1) < 0) { perror("F_NOCACHE"); return 1; }
        struct stat st; fstat(fd, &st);

        pthread_t th[8];
        Stripe s[8];
        off_t chunk = st.st_size / k;
        for (int i = 0; i < k; i++) {
            if (posix_memalign(&s[i].buf, ALIGN, bs)) { perror("memalign"); return 1; }
            s[i].fd = fd;
            s[i].bs = bs;
            s[i].start = (off_t)i * chunk;
            s[i].end = (i == k - 1) ? st.st_size : (off_t)(i + 1) * chunk;
        }
        uint64_t t0 = now_ns();
        for (int i = 0; i < k; i++) pthread_create(&th[i], NULL, worker, &s[i]);
        for (int i = 0; i < k; i++) pthread_join(th[i], NULL);
        double wall = (double)(now_ns() - t0) / 1e9;
        for (int i = 0; i < k; i++) free(s[i].buf);
        close(fd);

        printf("%3d   %9ld   %7s   %6.2f   %4.2f\n", k, bs >> 20,
               nocache ? "yes" : "no", wall, (double)st.st_size / wall / 1e9);
    }
    return 0;
}
