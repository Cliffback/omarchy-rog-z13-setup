/* scx-latency: measure scheduling wake-up latency without fork overhead.
 *
 * Repeatedly sleeps for a short interval and measures the actual elapsed time.
 * The overshoot is the scheduler's wake-up latency. Reports percentiles.
 *
 * Build: gcc -O2 -o scx-latency scx-latency.c
 * Usage: ./scx-latency [iterations] [sleep_us]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  long iters = (argc > 1) ? atol(argv[1]) : 2000;
  long sleep_us = (argc > 2) ? atol(argv[2]) : 1000;

  double *lat = malloc(sizeof(double) * iters);
  if (!lat) { perror("malloc"); return 1; }

  struct timespec req = { .tv_sec = sleep_us / 1000000,
                          .tv_nsec = (sleep_us % 1000000) * 1000 };

  for (long i = 0; i < iters; i++) {
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    nanosleep(&req, NULL);
    clock_gettime(CLOCK_MONOTONIC, &b);

    double elapsed_us = (b.tv_sec - a.tv_sec) * 1e6 +
                        (b.tv_nsec - a.tv_nsec) / 1e3;
    lat[i] = elapsed_us - (double)sleep_us;  /* overshoot = wake latency */
  }

  qsort(lat, iters, sizeof(double), cmp_double);

  double sum = 0;
  for (long i = 0; i < iters; i++) sum += lat[i];

  printf("wake latency overshoot over %ldus sleep (%ld samples):\n",
         sleep_us, iters);
  printf("  mean=%.0fus  p50=%.0fus  p95=%.0fus  p99=%.0fus  max=%.0fus\n",
         sum / iters,
         lat[iters * 50 / 100],
         lat[iters * 95 / 100],
         lat[iters * 99 / 100],
         lat[iters - 1]);

  free(lat);
  return 0;
}
