// Completion-owned upload storage. A block is immutable until its last GPU
// serial completes; exhaustion never rewinds a block still in flight.
#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <new>
#include <vector>

namespace gpu {
template <class Buffer> class UploadArena {
  public:
    struct Allocation {
        Buffer buffer;
        size_t offset;
    };
    template <class Make>
    Allocation allocate(size_t bytes, uint64_t serial, uint64_t completed, Make make) {
        const size_t aligned = (bytes + 15) & ~size_t(15);
        if (!current_.buffer || aligned > current_.capacity - cursor_) {
            // Bound idle retention, including unusual, oversized guest draws.
            if (current_.buffer && current_.capacity == block_size && spare_.size() < 8)
                spare_.push_back(current_);
            current_ = {};
            cursor_ = 0;
            auto ready = std::find_if(spare_.begin(), spare_.end(), [&](const Block &b) {
                return b.serial <= completed && b.capacity >= aligned;
            });
            if (ready != spare_.end()) {
                current_ = *ready;
                spare_.erase(ready);
            } else {
                current_.capacity = std::max(block_size, aligned);
                current_.buffer = make(current_.capacity);
                if (!current_.buffer)
                    throw std::bad_alloc();
            }
        }
        current_.serial = serial;
        Allocation result{current_.buffer, cursor_};
        cursor_ += aligned;
        return result;
    }

  private:
    static constexpr size_t block_size = 4u << 20;
    struct Block {
        Buffer buffer{};
        size_t capacity = 0;
        uint64_t serial = 0;
    };
    Block current_;
    size_t cursor_ = 0;
    std::vector<Block> spare_;
};
} // namespace gpu
