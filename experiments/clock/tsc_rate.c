// Measure this machine's TSC frequency against its own disciplined
// CLOCK_REALTIME, in back-to-back windows.
//
// Why this is the right measurement. The remote side stamps versions with
// RdmaOps::now(), and a range-query snapshot has to compare those stamps
// ACROSS machines. Two invariant TSCs tick at a constant rate but not at the
// SAME rate, and a one-shot reset corrects offset while leaving that rate
// difference to accumulate. So the quantity that decides whether a reset-once
// scheme is viable is the relative frequency error between machines, in ppm.
//
// Method: CLOCK_REALTIME is NTP-disciplined, and NTP corrects frequency as
// well as offset, so over a window of tens of seconds each node's own
// CLOCK_REALTIME is an accurate interval reference. Dividing the TSC delta by
// it yields that node's TSC frequency; differencing two nodes' frequencies
// yields their relative error. Residual NTP frequency error is the dominant
// noise term, which is why several windows are reported rather than one --
// the spread across windows is the measurement's own error bar.
//
// Output, one line per window:  <window> <elapsed_s> <tsc_ticks> <ticks_per_s>
//
// Requires an invariant TSC (constant_tsc + nonstop_tsc); rdtscp serialises,
// so the read is not reordered out of the window.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <x86intrin.h>

static double to_seconds(struct timespec t) {
  return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}

int main(int argc, char **argv) {
  int const window = argc > 1 ? atoi(argv[1]) : 30;
  int const reps = argc > 2 ? atoi(argv[2]) : 3;
  unsigned int aux;

  for (int i = 0; i < reps; i++) {
    struct timespec a, b;
    clock_gettime(CLOCK_REALTIME, &a);
    unsigned long long const t0 = __rdtscp(&aux);

    struct timespec req = {window, 0};
    nanosleep(&req, NULL);

    unsigned long long const t1 = __rdtscp(&aux);
    clock_gettime(CLOCK_REALTIME, &b);

    double const elapsed = to_seconds(b) - to_seconds(a);
    printf("%d %.9f %llu %.4f\n", i, elapsed, t1 - t0,
           (double)(t1 - t0) / elapsed);
    fflush(stdout);
  }
  return 0;
}
