// Pace UIKit impacts while the latest device-rumble request is nonzero. One
// timer owns each generation; a stop invalidates it before a new run can start.
#pragma once

#include <cstdint>

namespace controls {
class RumblePulses {
  public:
    static constexpr uint64_t kIntervalNs = 50000000; // at most 20 impacts/second
    struct Step {
        bool impact = false;
        bool schedule = false;
        uint64_t delay_ns = 0;
        uint64_t generation = 0;
    };

    Step request(uint16_t strength, uint64_t now_ns) {
        if (!strength) {
            stop();
            return {};
        }
        if (!active_) {
            active_ = true;
            ++generation_;
            next_ns_ = now_ns;
        }
        Step step;
        if (now_ns >= next_ns_) {
            step.impact = true;
            next_ns_ = now_ns + kIntervalNs;
        }
        if (!pending_) {
            pending_ = true;
            step.schedule = true;
            step.delay_ns = next_ns_ - now_ns;
            step.generation = generation_;
        }
        return step;
    }

    bool consume_timer(uint64_t generation) {
        if (!active_ || !pending_ || generation != generation_)
            return false;
        pending_ = false;
        return true;
    }
    void stop() {
        if (active_ || pending_)
            ++generation_;
        active_ = false;
        pending_ = false;
    }
    bool active() const {
        return active_;
    }

  private:
    uint64_t generation_ = 0, next_ns_ = 0;
    bool active_ = false, pending_ = false;
};
} // namespace controls
