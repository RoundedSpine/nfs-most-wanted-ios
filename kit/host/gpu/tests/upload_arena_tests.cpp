#include "../metal/upload_arena.h"
#include <cstdlib>
#include <cstdio>
#include <memory>
#include <vector>

#define CHECK(condition)                                                                           \
    do {                                                                                           \
        if (!(condition)) {                                                                        \
            std::fprintf(stderr, "failed at line %d: %s\n", __LINE__, #condition);                 \
            std::exit(1);                                                                          \
        }                                                                                          \
    } while (0)

int main() {
    using Buffer = std::shared_ptr<std::vector<unsigned char>>;
    gpu::UploadArena<Buffer> arena;
    size_t made = 0;
    auto make = [&](size_t bytes) {
        ++made;
        return std::make_shared<std::vector<unsigned char>>(bytes);
    };
    constexpr size_t block = 4u << 20;
    auto first = arena.allocate(4001, 1, 0, make);
    auto second = arena.allocate(16, 1, 0, make);
    CHECK(first.offset == 0 && second.offset == 4016);
    (*first.buffer)[0] = 123;
    auto pending = arena.allocate(block, 2, 0, make);
    CHECK(pending.buffer != first.buffer && made == 2);
    auto reused = arena.allocate(block, 3, 1, make);
    CHECK(reused.buffer == first.buffer && reused.offset == 0 && made == 2);
    // The serial of a reused block advances: it cannot be recycled again yet.
    auto still_pending = arena.allocate(block, 4, 1, make);
    CHECK(still_pending.buffer != reused.buffer && still_pending.buffer != pending.buffer);
    CHECK((*first.buffer)[0] == 123);
    // Oversized uploads don't strand the normal block or get rebound at a
    // misaligned offset, and unfinished resources remain caller-owned.
    auto large = arena.allocate(block + 1, 5, 4, make);
    CHECK(large.offset == 0 && large.buffer->size() >= block + 1);
    auto normal = arena.allocate(block, 6, 4, make);
    CHECK(normal.buffer != large.buffer && normal.offset == 0);
    // Steady-state allocation stays bounded despite multiple frames in flight.
    gpu::UploadArena<Buffer> steady;
    size_t steady_allocations = 0;
    for (uint64_t serial = 1; serial <= 100; ++serial) {
        auto allocation =
            steady.allocate(block, serial, serial > 3 ? serial - 3 : 0, [&](size_t bytes) {
                ++steady_allocations;
                return make(bytes);
            });
        CHECK(allocation.offset == 0);
    }
    CHECK(steady_allocations == 3);
    gpu::UploadArena<Buffer> failed;
    bool rejected = false;
    try {
        failed.allocate(16, 1, 0, [](size_t) { return Buffer{}; });
    } catch (const std::bad_alloc &) {
        rejected = true;
    }
    CHECK(rejected);
    CHECK(failed.allocate(16, 1, 0, make).buffer != nullptr);
    std::puts("upload_arena_tests: completion ownership, alignment and reuse passed");
}
