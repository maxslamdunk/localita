// Rewrite one file sequentially, in place, to change its NAND placement.
//
// THIS MODIFIES THE INSTALLED MODEL ARTIFACT. It is the end-to-end test of
// IO-12: the installer writes each layer_NN.bin scattered (RangeCopyPlanner
// re-sorts every copy by source offset), and a sequentially written copy of the
// same bytes reads ~1.3x faster at production's random slot granularity. This
// rewrites the bytes in one ascending pass so the file lands with sequential
// placement. Content is unchanged, byte for byte.
//
// Safety: writes to <file>.seqtmp, fsyncs it, re-reads it and compares a hash
// against the source, and only then rename()s over the original. rename() is
// atomic on APFS, so at every instant the path holds one complete valid file --
// either the old one or the new one. On any mismatch the temp is unlinked and
// the original is left untouched. Needs one file's worth of free space (0.41
// GiB for a layer file), not the whole corpus.
//
// Deliberately NO F_PREALLOCATE and no ftruncate: a preallocated file on this
// 92%-full volume measured WORSE than the installed artifact (18 extents/read),
// and the fresh_seq control that read at 2.30 GB/s was written exactly this way
// -- a plain ascending write() stream. Match the control.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>

#define CHUNK (8L << 20)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// FNV-1a over 64-bit words. Not a checksum for adversaries -- just enough to
// catch a short write, a torn chunk, or an offset bug before we rename.
static uint64_t hash_words(uint64_t h, const void *p, size_t n) {
    const uint64_t *w = (const uint64_t *)p;
    for (size_t i = 0; i < n / 8; i++) { h ^= w[i]; h *= 1099511628211ULL; }
    const unsigned char *tail = (const unsigned char *)p + (n / 8) * 8;
    for (size_t i = 0; i < n % 8; i++) { h ^= tail[i]; h *= 1099511628211ULL; }
    return h;
}

static int hash_file(const char *path, uint64_t *out, off_t *size_out) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); return -1; }
    void *buf = malloc(CHUNK);
    uint64_t h = 14695981039346656037ULL;
    off_t total = 0;
    for (;;) {
        ssize_t n = read(fd, buf, CHUNK);
        if (n < 0) { perror("read"); free(buf); close(fd); return -1; }
        if (n == 0) break;
        h = hash_words(h, buf, (size_t)n);
        total += n;
    }
    free(buf); close(fd);
    *out = h; *size_out = total;
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[2], "--commit") != 0) {
        fprintf(stderr, "usage: %s <file> --commit\n"
                        "  Rewrites <file> sequentially in place. Requires --commit,\n"
                        "  so a stray invocation cannot touch the model.\n", argv[0]);
        return 2;
    }
    const char *src = argv[1];

    char tmp[4096];
    if (snprintf(tmp, sizeof tmp, "%s.seqtmp", src) >= (int)sizeof tmp) {
        fprintf(stderr, "path too long\n"); return 1;
    }

    struct stat st;
    if (stat(src, &st) != 0) { perror(src); return 1; }

    int in = open(src, O_RDONLY);
    if (in < 0) { perror(src); return 1; }
    int out = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (out < 0) { perror(tmp); close(in); return 1; }

    void *buf = malloc(CHUNK);
    uint64_t hsrc = 14695981039346656037ULL;
    off_t written = 0;
    uint64_t t0 = now_ns();
    for (;;) {
        ssize_t n = read(in, buf, CHUNK);
        if (n < 0) { perror("read"); goto fail; }
        if (n == 0) break;
        hsrc = hash_words(hsrc, buf, (size_t)n);
        // One ascending write stream. This is the whole point of the exercise.
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out, (char *)buf + off, (size_t)(n - off));
            if (w <= 0) { perror("write"); goto fail; }
            off += w;
        }
        written += n;
    }
    if (fsync(out) != 0) { perror("fsync"); goto fail; }
    close(out); close(in); free(buf); buf = NULL;
    double wsec = (double)(now_ns() - t0) / 1e9;

    if (written != st.st_size) {
        fprintf(stderr, "SIZE MISMATCH: src %lld, tmp %lld -- not renaming\n",
                (long long)st.st_size, (long long)written);
        unlink(tmp); return 1;
    }

    uint64_t htmp; off_t tsize;
    if (hash_file(tmp, &htmp, &tsize) != 0) { unlink(tmp); return 1; }
    if (tsize != st.st_size || htmp != hsrc) {
        fprintf(stderr, "HASH/SIZE MISMATCH: src %016llx/%lld tmp %016llx/%lld -- not renaming\n",
                (unsigned long long)hsrc, (long long)st.st_size,
                (unsigned long long)htmp, (long long)tsize);
        unlink(tmp); return 1;
    }

    if (rename(tmp, src) != 0) { perror("rename"); unlink(tmp); return 1; }

    // Persist the directory entry too, so a crash cannot leave the rename
    // half-applied in the volume's metadata.
    char dir[4096];
    strncpy(dir, src, sizeof dir - 1); dir[sizeof dir - 1] = 0;
    char *slash = strrchr(dir, '/');
    if (slash) { *slash = 0; int dfd = open(dir, O_RDONLY); if (dfd >= 0) { fsync(dfd); close(dfd); } }

    const char *base = src;
    for (const char *p = src; *p; p++) if (*p == '/') base = p + 1;
    printf("  %-16s rewrote %lld B in %.1f s (%.2f GB/s), hash %016llx OK\n",
           base, (long long)written, wsec, (double)written / wsec / 1e9,
           (unsigned long long)hsrc);
    return 0;

fail:
    if (buf) free(buf);
    close(out); close(in);
    unlink(tmp);
    return 1;
}
