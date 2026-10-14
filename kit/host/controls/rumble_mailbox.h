// A bounded handoff from guest rumble producers to the main-thread player.
// Only one drain owns the mailbox, even while framework calls are executing.
#pragma once

#include <cstdint>
#include <mutex>

namespace controls {
class RumbleMailbox {
  public:
    struct Request {
        uint16_t strength;
        uint64_t sequence;
        bool active;
    };

    // True assigns ownership of one main-queue drain. Other producers only
    // replace its desired strength, including stops, without queuing work.
    bool publish(uint16_t strength) {
        std::lock_guard lock(mutex_);
        if (!active_ || terminated_)
            return false;
        strength_ = strength;
        ++sequence_;
        if (pending_)
            return false;
        pending_ = true;
        return true;
    }

    Request latest() {
        std::lock_guard lock(mutex_);
        return {strength_, sequence_, active_ && !terminated_};
    }

    // Check after framework calls. A concurrent stop must get another drain
    // before ownership is released. Each drain yields to other main-queue work.
    bool finish(uint64_t consumed_sequence) {
        std::lock_guard lock(mutex_);
        if (sequence_ != consumed_sequence)
            return true;
        pending_ = false;
        return false;
    }

    // Invalidate queued vibration across background/foreground transitions.
    // pending_ stays set until its already queued owner has finished.
    void set_active(bool active) {
        std::lock_guard lock(mutex_);
        active_ = active && !terminated_;
        strength_ = 0;
        ++sequence_;
    }

    void terminate() {
        std::lock_guard lock(mutex_);
        terminated_ = true;
        active_ = false;
        strength_ = 0;
        ++sequence_;
    }

  private:
    std::mutex mutex_;
    uint16_t strength_ = 0;
    uint64_t sequence_ = 0;
    bool pending_ = false, active_ = true, terminated_ = false;
};
} // namespace controls
