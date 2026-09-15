// Sequential read of one file at a chosen block size, two passes.
// Pass 1 is cold-ish, pass 2 shows what the page cache contributes, so a warm
// result cannot be mistaken for device throughput.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
#include <stdint.h>

#define ALIGN (2L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static double pass(int fd, void *buf, long bs, off_t size) {
    uint64_t t0 = now_ns();
    off_t off = 0;
    while (off < size) {
        long want = (size - off) < bs ? (long)(size - off) : bs;
        ssize_t got = pread(fd, buf, want, off);
        if (got != want) { perror("pread"); exit(1); }
        off += got;
    }
    double s = (double)(now_ns() - t0) / 1e9;
    return (double)size / s / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [block_mib]\n", argv[0]); return 2; }
    long bs = (argc > 2 ? atol(argv[2]) : 8) << 20;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror(argv[1]); return 1; }
    struct stat st; fstat(fd, &st);
    void *buf;
    if (posix_memalign(&buf, ALIGN, bs)) { perror("memalign"); return 1; }
    printf("  %s  %.2f GiB, %ld MiB blocks: pass1 %.2f GB/s", argv[1],
           (double)st.st_size / 1073741824.0, bs >> 20, pass(fd, buf, bs, st.st_size));
    printf(", pass2 %.2f GB/s\n", pass(fd, buf, bs, st.st_size));
    return 0;
}
