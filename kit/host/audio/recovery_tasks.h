// Audio recovery may wait for a device to return. Own those workers so they
// can be cancelled and joined before the host destroys SDL's audio state.
#pragma once

#include <chrono>
#include <condition_variable>
#include <algorithm>
#include <functional>
#include <future>
#include <mutex>
#include <utility>
#include <vector>

class AudioRecoveryTasks {
  public:
    ~AudioRecoveryTasks() {
        stop();
    }

    bool start(std::function<void(AudioRecoveryTasks &)> task) {
        std::lock_guard lock(mutex_);
        if (stopping_)
            return false;
        // Ready async futures have finished their threads. Reclaim their
        // handles on each request instead of retaining every past recovery
        // until shutdown. In-flight jobs remain independent and cancellable.
        std::erase_if(workers_, [](auto &worker) {
            return worker.wait_for(std::chrono::seconds(0)) == std::future_status::ready;
        });
        workers_.push_back(std::async(std::launch::async,
                                      [this, task = std::move(task)]() noexcept { task(*this); }));
        return true;
    }

    // True means cancelled. A notification interrupts even long device waits.
    bool wait(std::chrono::milliseconds duration) {
        std::unique_lock lock(mutex_);
        return changed_.wait_for(lock, duration, [this] { return stopping_; });
    }

    void stop() {
        std::vector<std::future<void>> workers;
        {
            std::lock_guard lock(mutex_);
            stopping_ = true;
            workers.swap(workers_);
        }
        changed_.notify_all();
        for (auto &worker : workers)
            worker.wait();
    }

  private:
    std::mutex mutex_;
    std::condition_variable changed_;
    bool stopping_ = false;
    std::vector<std::future<void>> workers_;
};
