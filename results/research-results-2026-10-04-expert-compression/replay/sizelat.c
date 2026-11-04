// sizelat: serial (QD1) pread latency against request size, on the installed
// expert files, F_NOCACHE, random expert, read from the expert's start.
// Sizes are interleaved round-robin so drift hits them all alike. Fits
// t = a + bytes / B by least squares over the per-size medians.
//
//   cc -O3 -o sizelat sizelat.c && sizelat <packed_experts> [reads per size]
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define STRIDE 3358720
static const size_t SIZES[] = {65536, 131072, 262144, 524288, 1048576, 2097152, 2887680, 3358720};
#define NS (sizeof SIZES / sizeof SIZES[0])

static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }
static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv) {
  int reps = argc > 2 ? atoi(argv[2]) : 150;
  int fds[30];
  char path[1024];
  for (int l = 0; l < 30; l++) {
    snprintf(path, sizeof path, "%s/layer_%02d.bin", argv[1], l);
    fds[l] = open(path, O_RDONLY);
    if (fds[l] < 0) { perror(path); return 1; }
    fcntl(fds[l], F_NOCACHE, 1);
  }
  void *buf; posix_memalign(&buf, 16384, STRIDE);
  double *t = calloc(NS * reps, sizeof(double));
  srand48(20261004);
  for (int r = 0; r < reps; r++)
    for (size_t s = 0; s < NS; s++) {
      int l = (int)(drand48() * 30), e = (int)(drand48() * 128);
      double a = now();
      if (pread(fds[l], buf, SIZES[s], (off_t)e * STRIDE) != (ssize_t)SIZES[s]) { perror("pread"); return 1; }
      t[s * reps + r] = (now() - a) * 1e6;
    }
  double sx = 0, sy = 0, sxx = 0, sxy = 0;
  printf("bytes      p50 us   mean us   GB/s (bytes / mean)\n");
  for (size_t s = 0; s < NS; s++) {
    double *v = t + s * reps, m = 0;
    for (int r = 0; r < reps; r++) m += v[r];
    m /= reps;
    qsort(v, reps, sizeof(double), cmp);
    double p50 = v[reps / 2];
    printf("%8zu  %8.0f  %8.0f   %.3f\n", SIZES[s], p50, m, SIZES[s] / m / 1e3);
    double x = (double)SIZES[s], y = m;
    sx += x; sy += y; sxx += x * x; sxy += x * y;
  }
  double slope = (NS * sxy - sx * sy) / (NS * sxx - sx * sx), icpt = (sy - slope * sx) / NS;
  printf("fit over means: t = %.0f us + bytes / %.3f GB/s\n", icpt, 1e-3 / slope);
  return 0;
}
