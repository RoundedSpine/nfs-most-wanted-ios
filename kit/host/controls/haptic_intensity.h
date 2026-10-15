// Main-queue pacing for one continuous device player. Stops bypass this class;
// deferred updates read the latest mailbox value rather than replaying history.
#pragma once

#include <cstdint>

namespace controls {
class HapticIntensity {
  public:
    static constexpr uint64_t kIntervalNs = 16666667; // at most 60 changes/second

    void applied(uint16_t strength, uint64_t now_ns) {
        strength_ = strength;
        next_ns_ = now_ns + kIntervalNs;
    }
    bool unchanged(uint16_t strength) const {
        return strength == strength_;
    }
    uint64_t delay_ns(uint64_t now_ns) const {
        return now_ns < next_ns_ ? next_ns_ - now_ns : 0;
    }

  private:
    uint16_t strength_ = 0;
    uint64_t next_ns_ = 0;
};
} // namespace controls
