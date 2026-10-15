// Completion can arrive off the main queue before queued owner cleanup. Each
// player has a separate token so a late old callback cannot invalidate a new one.
#pragma once

#include <atomic>
#include <cstdint>

namespace controls {
class HapticPlayerState {
  public:
    explicit HapticPlayerState(uint64_t engine_epoch) : engine_epoch_(engine_epoch) {}
    void complete() {
        completed_.store(true, std::memory_order_release);
    }
    bool usable(uint64_t engine_epoch) const {
        return engine_epoch == engine_epoch_ && !completed_.load(std::memory_order_acquire);
    }

  private:
    const uint64_t engine_epoch_;
    std::atomic<bool> completed_{false};
};
} // namespace controls
