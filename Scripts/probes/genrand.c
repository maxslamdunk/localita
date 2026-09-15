// Fast incompressible-data writer (xorshift128+), for a probe file whose bytes
// the SSD controller cannot dedupe or compress away.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <file> <mib>\n", argv[0]); return 2; }
    long mib = atol(argv[2]);
    int fd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror(argv[1]); return 1; }
    size_t chunk = 1 << 20;
    uint64_t *buf = malloc(chunk);
    uint64_t s0 = 0x9E3779B97F4A7C15ull, s1 = 0xBF58476D1CE4E5B9ull;
    for (long m = 0; m < mib; m++) {
        for (size_t i = 0; i < chunk / 8; i++) {
            uint64_t x = s0, y = s1;
            s0 = y; x ^= x << 23; s1 = x ^ y ^ (x >> 17) ^ (y >> 26);
            buf[i] = s1 + y;
        }
        if (write(fd, buf, chunk) != (ssize_t)chunk) { perror("write"); return 1; }
    }
    fsync(fd);
    close(fd);
    return 0;
}
