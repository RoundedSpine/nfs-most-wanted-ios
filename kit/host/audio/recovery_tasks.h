// Audio recovery may wait for a device to return. Own those workers so they
// can be cancelled and joined before the host destroys SDL's audio state.
#pragma once

#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
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
        workers_.emplace_back([this, task = std::move(task)] { task(*this); });
        return true;
    }

    // True means cancelled. A notification interrupts even long device waits.
    bool wait(std::chrono::milliseconds duration) {
        std::unique_lock lock(mutex_);
        return changed_.wait_for(lock, duration, [this] { return stopping_; });
    }

    void stop() {
        std::vector<std::thread> workers;
        {
            std::lock_guard lock(mutex_);
            stopping_ = true;
            workers.swap(workers_);
        }
        changed_.notify_all();
        for (auto &worker : workers)
            worker.join();
    }

  private:
    std::mutex mutex_;
    std::condition_variable changed_;
    bool stopping_ = false;
    std::vector<std::thread> workers_;
};
