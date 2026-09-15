// Physical layout QUALITY, beyond extent count.
//
// extents/read counts how many pieces a read is split into. It is blind to how
// those pieces are arranged: a file whose extents march forward through
// physical space reads differently from one whose extents jump backwards, even
// at an identical count. Two files on this volume with 7.84 and 7.82
// extents/read differ by 17% in sequential throughput, so count is provably not
// the whole story.
//
// Reports, per file:
//   forward%    fraction of extent boundaries where the next extent lies at a
//               HIGHER physical address than the end of the current one
//   mean |jump| average absolute distance between end of extent i and start of
//               extent i+1, in MiB
//   spread      (max physical address - min) / file size. 1.0 means the file
//               occupies a physical span no larger than itself; 10.0 means its
//               blocks are scattered over ten times its own size.
//
// Metadata only via F_LOG2PHYS_EXT -- reads zero file bytes.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdint.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file> [file...]\n", argv[0]); return 2; }
    printf("%-24s  %8s  %9s  %11s  %8s  %8s\n",
           "file", "extents", "forward%", "mean|jump|", "spread", "size_GiB");
    for (int a = 1; a < argc; a++) {
        int fd = open(argv[a], O_RDONLY);
        if (fd < 0) { perror(argv[a]); continue; }
        struct stat st; fstat(fd, &st);

        off_t logical = 0;
        long n = 0, forward = 0;
        double jump_sum = 0;
        off_t prev_end = -1;
        off_t phys_min = -1, phys_max = 0;

        while (logical < st.st_size) {
            struct log2phys l2p;
            l2p.l2p_contigbytes = st.st_size - logical;
            l2p.l2p_devoffset = logical;
            if (fcntl(fd, F_LOG2PHYS_EXT, &l2p) < 0) { perror("F_LOG2PHYS_EXT"); break; }
            off_t start = l2p.l2p_devoffset;
            off_t len = l2p.l2p_contigbytes;
            if (len <= 0) break;

            if (phys_min < 0 || start < phys_min) phys_min = start;
            if (start + len > phys_max) phys_max = start + len;

            if (prev_end >= 0) {
                if (start >= prev_end) forward++;
                double d = (double)(start > prev_end ? start - prev_end : prev_end - start);
                jump_sum += d;
            }
            prev_end = start + len;
            logical += len;
            n++;
        }
        close(fd);
        if (n < 2) { printf("%-24s  (too few extents)\n", argv[a]); continue; }

        const char *base = argv[a];
        for (const char *p = argv[a]; *p; p++) if (*p == '/') base = p + 1;
        printf("%-24s  %8ld  %8.1f%%  %8.2f MiB  %8.2f  %8.2f\n",
               base, n, 100.0 * (double)forward / (double)(n - 1),
               jump_sum / (double)(n - 1) / 1048576.0,
               (double)(phys_max - phys_min) / (double)st.st_size,
               (double)st.st_size / 1073741824.0);
    }
    return 0;
}
