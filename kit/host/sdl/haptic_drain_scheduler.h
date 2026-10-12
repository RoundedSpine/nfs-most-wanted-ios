#pragma once
#include "haptic_request_mailbox.h"
#include <atomic>
#include <cstdint>
// A single owner (the main queue) drains the latest atomic request.
// Producers only publish and claim a scheduling token.
class HapticDrainScheduler {
public:
 using Snapshot=HapticRequestMailbox::Snapshot;
 bool publish(uint16_t low,uint16_t high) noexcept {
  mailbox_.publish(low,high);
  return !scheduled_.exchange(true,std::memory_order_acq_rel);
 }
 Snapshot latest() const noexcept {return mailbox_.latest();}
 bool current(Snapshot s) const noexcept {return mailbox_.current(s);}
 // Called by the sole main-queue owner after processing one snapshot.
 // Returns true if another snapshot must be processed before releasing ownership.
 bool next(Snapshot processed) noexcept {
  if(!current(processed)) return true;
  scheduled_.store(false,std::memory_order_release);
  // A producer may have published between current() and store(false).
  // The caller reclaims ownership and continues processing in that case.
  if(current(processed)) return false;
  return !scheduled_.exchange(true,std::memory_order_acq_rel);
 }
private:
 HapticRequestMailbox mailbox_;
 std::atomic<bool> scheduled_{false};
};
