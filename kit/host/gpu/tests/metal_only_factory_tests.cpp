// Exercise the real factory with Metal stubs, deliberately providing no
// Vulkan definitions. Any unguarded Vulkan reference must fail the link.
#include "../gpu_factory.h"
#include "../fake/fake_device.h"
#include "../../../platform/os.h"
#include <cstdio>
#include <cstring>
#include <string>

namespace {
int surface, created = 0, acquired = 0, released = 0;
int failures = 0, checks = 0;
#define CHECK(condition)                                                                           \
    do {                                                                                           \
        ++checks;                                                                                  \
        if (!(condition)) {                                                                        \
            ++failures;                                                                            \
            std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition);                      \
        }                                                                                          \
    } while (0)
} // namespace

namespace gpu {
std::unique_ptr<Device> metal_create_device() {
    ++created;
    return std::make_unique<FakeDevice>();
}
void *metal_test_native_surface(int w, int h) {
    CHECK(w == 640 && h == 480);
    ++acquired;
    return &surface;
}
void *metal_native_surface_for_window(void *window) {
    ++acquired;
    return window;
}
void metal_release_window_surface(void *value) {
    CHECK(value == &surface);
    ++released;
}
} // namespace gpu

int main() {
    const char *previous = recomp_env("GPU_BACKEND");
    const bool had_previous = previous != nullptr;
    const std::string saved = previous ? previous : "";
    const char *supported[] = {nullptr, "", "metal"};
    for (const char *choice : supported) {
        if (choice)
            os_setenv("RECOMP_GPU_BACKEND", choice);
        else
            os_unsetenv("RECOMP_GPU_BACKEND");
        CHECK(std::strcmp(gpu::default_backend_name(), "metal") == 0);
        CHECK(gpu::create_default_device() != nullptr);
        CHECK(gpu::test_native_surface(640, 480) == &surface);
        CHECK(gpu::native_surface_for_window(&surface) == &surface);
        gpu::release_window_surface(&surface);
        CHECK(gpu::vulkan_loader_path() == nullptr);
    }
    CHECK(created == 3 && acquired == 6 && released == 3);
    for (const char *choice : {"vulkan", "unknown"}) {
        os_setenv("RECOMP_GPU_BACKEND", choice);
        CHECK(std::strcmp(gpu::default_backend_name(), "none") == 0);
        CHECK(gpu::create_default_device() == nullptr);
        CHECK(gpu::test_native_surface(640, 480) == nullptr);
        CHECK(gpu::native_surface_for_window(&surface) == nullptr);
        gpu::release_window_surface(&surface);
        CHECK(gpu::vulkan_loader_path() == nullptr);
    }
    CHECK(created == 3 && acquired == 6 && released == 3);
    if (had_previous)
        os_setenv("RECOMP_GPU_BACKEND", saved.c_str());
    else
        os_unsetenv("RECOMP_GPU_BACKEND");
    std::printf("metal_only_factory_tests: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
