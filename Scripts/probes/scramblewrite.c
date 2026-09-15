// Copy a file, writing its blocks in shuffled order.
//
// Discriminates two reasons a freshly written file might read faster than an
// old one:
//   (a) recency  -- SLC residency, or FTL mapping entries still in controller
//                   DRAM. Both are properties of WHEN the bytes were written
//                   and both decay.
//   (b) placement -- a sequential write lands in consecutive NAND pages striped
//                   across dies, and that parallelism survives until garbage
//                   collection moves the data.
//
// Both files are equally fresh, so (a) affects them equally. Only (b) cares
// that arrival order was scrambled relative to logical order. Use a block size
// small enough that one block cannot saturate the channels on its own -- 8 MiB
// is too coarse to be a real test.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdint.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <src> <dst> <block_kib>\n", argv[0]); return 2; }
    long bs = atol(argv[3]) << 10;

    int in = open(argv[1], O_RDONLY);
    if (in < 0) { perror(argv[1]); return 1; }
    struct stat st; fstat(in, &st);
    long nblocks = (st.st_size + bs - 1) / bs;

    int out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) { perror(argv[2]); return 1; }

    long *order = malloc((size_t)nblocks * sizeof(long));
    for (long i = 0; i < nblocks; i++) order[i] = i;
    srandom(42);
    for (long i = nblocks - 1; i > 0; i--) {          // Fisher-Yates
        long j = random() % (i + 1);
        long t = order[i]; order[i] = order[j]; order[j] = t;
    }

    void *buf;
    if (posix_memalign(&buf, 1 << 20, bs)) { perror("memalign"); return 1; }
    for (long k = 0; k < nblocks; k++) {
        long b = order[k];
        off_t off = (off_t)b * bs;
        long want = (st.st_size - off) < bs ? (long)(st.st_size - off) : bs;
        if (pread(in, buf, want, off) != want) { perror("pread"); return 1; }
        if (pwrite(out, buf, want, off) != want) { perror("pwrite"); return 1; }
    }
    fsync(out);
    close(out); close(in); free(buf); free(order);
    printf("wrote %s: %ld blocks of %ld KiB in shuffled order\n", argv[2], nblocks, bs >> 10);
    return 0;
}
