/*
 * NFSMW iOS performance meter (testing branch only).
 *
 * Header-only C99 implementation. Call nfsmw_perf_present() only from the
 * renderer's successful PRESENT path, once per completed frame, with a
 * monotonic timestamp in seconds (e.g. CACurrentMediaTime()).
 *
 * This is NOT a CADisplayLink refresh-rate counter. No UI or game timing
 * changes are performed here. UI integration is deliberately separate.
 */
#ifndef NFSMW_IOS_PERF_METER_H
#define NFSMW_IOS_PERF_METER_H

#include <stddef.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#define NFSMW_PERF_WINDOW 240u

typedef struct {
    double last_present;
    double frame_ms[NFSMW_PERF_WINDOW];
    unsigned next;
    unsigned count;
    int running;
} NfsmwPerfMeter;

typedef struct {
    double average_fps;
    double average_frame_ms;
    double one_percent_low_fps;
    double p95_frame_ms;
    unsigned samples;
} NfsmwPerfStats;

static inline void nfsmw_perf_reset(NfsmwPerfMeter *meter) {
    if (meter) memset(meter, 0, sizeof(*meter));
}

/* Call on pause/resume to avoid counting time spent in the background. */
static inline void nfsmw_perf_resume(NfsmwPerfMeter *meter) {
    nfsmw_perf_reset(meter);
}

static inline void nfsmw_perf_present(NfsmwPerfMeter *meter, double monotonic_seconds) {
    if (!meter || !isfinite(monotonic_seconds)) return;
    if (!meter->running) {
        meter->last_present = monotonic_seconds;
        meter->running = 1;
        return;
    }
    double elapsed = monotonic_seconds - meter->last_present;
    meter->last_present = monotonic_seconds;
    /* Ignore pauses and invalid samples; reset after large gaps. */
    if (elapsed > 1.0) {
        nfsmw_perf_reset(meter);
        meter->last_present = monotonic_seconds;
        meter->running = 1;
        return;
    }
    if (elapsed <= 0.0) return;
    meter->frame_ms[meter->next] = elapsed * 1000.0;
    meter->next = (meter->next + 1u) % NFSMW_PERF_WINDOW;
    if (meter->count < NFSMW_PERF_WINDOW) ++meter->count;
}

static inline void nfsmw_perf_stats(const NfsmwPerfMeter *meter, NfsmwPerfStats *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!meter || !meter->count) return;
    double sorted[NFSMW_PERF_WINDOW];
    double sum = 0.0;
    unsigned n = meter->count;
    for (unsigned i = 0; i < n; ++i) {
        sorted[i] = meter->frame_ms[i];
        sum += sorted[i];
    }
    /* Insertion sort is cheap for a small snapshot and never runs per frame. */
    for (unsigned i = 1; i < n; ++i) {
        double v = sorted[i];
        unsigned j = i;
        while (j && sorted[j - 1] > v) {
            sorted[j] = sorted[j - 1];
            --j;
        }
        sorted[j] = v;
    }
    out->samples = n;
    out->average_frame_ms = sum / n;
    out->average_fps = 1000.0 / out->average_frame_ms;
    unsigned p95 = (unsigned)ceil(0.95 * n);
    if (p95) --p95;
    out->p95_frame_ms = sorted[p95];
    /* 1% low: average of the slowest ceil(1% of frames), in FPS. */
    unsigned worst = (n + 99u) / 100u;
    double slow_sum = 0.0;
    for (unsigned i = n - worst; i < n; ++i) slow_sum += sorted[i];
    out->one_percent_low_fps = 1000.0 / (slow_sum / worst);
}
#endif
