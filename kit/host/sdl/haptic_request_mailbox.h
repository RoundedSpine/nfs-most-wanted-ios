#pragma once
#include <atomic>
#include <cstdint>
#include <algorithm>

// Thread-safe latest-value mailbox. A single atomic packs the request version
// and intensity, avoiding a torn version/intensity pair on concurrent producers.
// Versions wrap at 48 bits; a snapshot is immutable after publication.
class HapticRequestMailbox {
public:
 struct Snapshot { uint64_t version; uint16_t intensity; };
 Snapshot publish(uint16_t low,uint16_t high) noexcept {
  const uint16_t intensity=std::max(low,high);
  uint64_t prior=value_.load(std::memory_order_relaxed), next;
  do {
   next=(((prior>>16)+1)&0x0000FFFFFFFFFFFFULL)<<16 | intensity;
  } while(!value_.compare_exchange_weak(prior,next,std::memory_order_acq_rel,std::memory_order_relaxed));
  return {next>>16,static_cast<uint16_t>(next)};
 }
 Snapshot latest() const noexcept {
  auto v=value_.load(std::memory_order_acquire);
  return {v>>16,static_cast<uint16_t>(v)};
 }
 bool current(Snapshot s) const noexcept {
  return value_.load(std::memory_order_acquire)==((s.version<<16)|s.intensity);
 }
private:
 std::atomic<uint64_t> value_{0};
};
