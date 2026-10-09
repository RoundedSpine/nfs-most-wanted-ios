#include "../kit/ios_perf_meter.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    NfsmwPerfMeter m = {0};
    NfsmwPerfStats s;
    double t = 100.0;
    nfsmw_perf_present(&m, t);
    for (int i = 0; i < 120; ++i) {
        t += 1.0 / 60.0;
        nfsmw_perf_present(&m, t);
    }
    nfsmw_perf_stats(&m, &s);
    assert(s.samples == 120);
    assert(s.average_fps > 59.9 && s.average_fps < 60.1);
    assert(s.one_percent_low_fps > 59.9 && s.one_percent_low_fps < 60.1);
    assert(s.p95_frame_ms > 16.6 && s.p95_frame_ms < 16.7);
    nfsmw_perf_resume(&m);
    nfsmw_perf_stats(&m, &s);
    assert(s.samples == 0);
    puts("Performance meter tests passed");
    return 0;
}
