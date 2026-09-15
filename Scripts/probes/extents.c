// Extent-map probe: counts APFS extents in a file and how many extents a
// production-sized routed-expert read (3,358,720 B) has to span.
// Reads zero bytes of file content; F_LOG2PHYS_EXT is metadata only.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define SLOT 3358720L

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [file...]\n", argv[0]); return 2; }

    for (int a = 1; a < argc; a++) {
        int fd = open(argv[a], O_RDONLY);
        if (fd < 0) { perror(argv[a]); continue; }
        struct stat st;
        if (fstat(fd, &st) != 0) { perror("fstat"); close(fd); continue; }
        off_t size = st.st_size;

        // Collect extents.
        long cap = 1 << 16, n = 0;
        off_t *phys = malloc(cap * sizeof(off_t));
        off_t *len  = malloc(cap * sizeof(off_t));
        off_t *lstart = malloc(cap * sizeof(off_t));
        off_t off = 0;
        while (off < size) {
            struct log2phys l2p;
            memset(&l2p, 0, sizeof(l2p));
            l2p.l2p_devoffset = off;
            l2p.l2p_contigbytes = size - off;
            if (fcntl(fd, F_LOG2PHYS_EXT, &l2p) != 0) { perror("F_LOG2PHYS_EXT"); break; }
            if (l2p.l2p_contigbytes <= 0) break;
            if (n == cap) {
                cap *= 2;
                phys = realloc(phys, cap * sizeof(off_t));
                len  = realloc(len,  cap * sizeof(off_t));
                lstart = realloc(lstart, cap * sizeof(off_t));
            }
            lstart[n] = off; phys[n] = l2p.l2p_devoffset; len[n] = l2p.l2p_contigbytes;
            n++;
            off += l2p.l2p_contigbytes;
        }

        // Extent size stats.
        off_t minlen = size, maxlen = 0;
        for (long i = 0; i < n; i++) { if (len[i] < minlen) minlen = len[i]; if (len[i] > maxlen) maxlen = len[i]; }

        // How many extents does each production-sized slot read span, and are
        // consecutive extents physically adjacent (a seek-free run)?
        long nslots = size / SLOT;
        long span_total = 0, span_max = 0, slots_multi = 0;
        long e = 0;
        for (long s = 0; s < nslots; s++) {
            off_t a0 = s * SLOT, a1 = a0 + SLOT;
            while (e < n && lstart[e] + len[e] <= a0) e++;
            long span = 0;
            for (long i = e; i < n && lstart[i] < a1; i++) span++;
            span_total += span;
            if (span > span_max) span_max = span;
            if (span > 1) slots_multi++;
        }

        long adjacent = 0;
        for (long i = 1; i < n; i++) if (phys[i] == phys[i-1] + len[i-1]) adjacent++;

        printf("%s\n", argv[a]);
        printf("  size            %lld B (%ld slots of %ld B)\n", (long long)size, nslots, SLOT);
        printf("  extents         %ld  (mean %.2f MiB, min %.1f KiB, max %.2f MiB)\n",
               n, (double)size / n / 1048576.0, (double)minlen / 1024.0, (double)maxlen / 1048576.0);
        printf("  phys-adjacent   %ld / %ld extent boundaries are seek-free\n", adjacent, n > 0 ? n - 1 : 0);
        printf("  extents/read    mean %.2f, max %ld; %ld/%ld reads (%.1f%%) span >1 extent\n",
               (double)span_total / (double)nslots, span_max, slots_multi, nslots,
               100.0 * (double)slots_multi / (double)nslots);
        free(phys); free(len); free(lstart);
        close(fd);
    }
    return 0;
}
