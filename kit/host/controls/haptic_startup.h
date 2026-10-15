// Main-queue ownership of asynchronous engine startup. A reset or shutdown
// invalidates its ticket before a delayed framework completion can resume rumble.
#pragma once

#include <cstdint>

namespace controls {
class HapticStartup {
  public:
    bool pending() const {
        return pending_;
    }
    uint64_t begin() {
        pending_ = true;
        return ++generation_;
    }
    bool complete(uint64_t ticket) {
        if (!pending_ || ticket != generation_)
            return false;
        pending_ = false;
        return true;
    }
    void invalidate() {
        pending_ = false;
        ++generation_;
    }

  private:
    uint64_t generation_ = 0;
    bool pending_ = false;
};
} // namespace controls
