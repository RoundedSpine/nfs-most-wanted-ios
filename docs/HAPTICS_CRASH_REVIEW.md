# Core Haptics native-crash review (historical)

The custom backend reviewed here has been replaced by UIKit impact pulses.
These findings describe the removed implementation. The diagnostic dynamic-update
switch below is obsolete; current behavior is documented in [Troubleshooting](TROUBLESHOOTING.md).

The supplied app trace reaches engine start completion, player start, and a live
intensity update. It has no native stack or signal record. This establishes that
the main startup calls returned successfully, not that playback was healthy on
all framework threads or that sendParameters was the failing instruction.

## Confirmed contract violation: null callbacks during shutdown

[The iOS bridge](../kit/host/sdl/platform_ui_ios.mm) assigned nil to stoppedHandler,
resetHandler, and the advanced player's completionHandler during shutdown. The
iOS SDK declares these properties non-null; earlier SDK build logs contain three
Wnonnull warnings. Removed these assignments. Every callback already checks the
terminal shutdown flag, and player generations invalidate queued cleanup. The
SDK check now treats non-null violations as errors.

This violates the declared API contract, but a native assertion or callback
failure is only a possible consequence. The provided log does not show shutdown,
so this does not establish the cause of the first-vibration crash.

## Completion, reset and stop can overlap an update

A framework completion callback can run before its main-queue cleanup. Per-player
atomic completion tokens now block updates and stop calls after that completion
has been observed. Tokens belong to each player so late old callbacks cannot
invalidate a replacement. Atomic engine epochs similarly invalidate players on
stop/reset. State is rechecked immediately before live parameter submission.

These checks cannot prevent a framework state change during a framework call.
Core Haptics must handle that transition internally. Adding a host mutex across
framework calls and callbacks could introduce a deadlock and is not a solution.

The stopped/reset callbacks now publish invalidation immediately, then defer
logging and ownership cleanup to the main queue. Queued cleanup checks shutdown
again before doing work. This keeps file/stdio locking off framework callback
threads and adds stopped/reset evidence to the app trace.

## Diagnostic limitation: native threads can be labeled as guest crashes

[The host fault handler](../kit/host/boot.cpp) handles process-wide signals and
always prints guest registers. The runtime defaults a native thread's guest ID
to 1 and guest_current_context falls back to the loader context. A fault on a
Core Haptics or audio worker can therefore print an unrelated guest EIP. The
handler then exits directly, which can suppress the operating system's ordinary
fatal-signal reporting. This is a reporting limitation, not evidence that it
caused the original fault. Do not attribute such a native fault to the printed
guest address without a native thread stack.

## What did not show an API misuse

- A uint16 strength divided by 65535 produces a finite intensity within 0..1.
- Apple documents a zero/past engine time as immediate parameter submission.
- The engine is configured for haptics-only playback before startup.
- Objective-C engine/player ownership uses ARC, with main-queue mutation and
  strong local ownership through stop/update calls.
- The device path uses iOS Core Haptics and UIKit, not macOS-only dependencies.
- SDL's controller rumble also uses continuous Core Haptics events and immediate
  dynamic intensity controls. That corroborates the general API sequence; its
  controller-specific infinite duration is not appropriate evidence for using
  an infinite event on the phone motor.

## Most informative device test

First test the updated bridge normally. If it still crashes, set
RECOMP_HAPTICS_DYNAMIC_UPDATES=0 in Documents/switches.txt and restart. This keeps
the same looping continuous player and normal stops, holding the initial strength
for each effect. If this avoids the crash, live parameter changes or their timing
are implicated; it still does not prove a specific framework bug. If it crashes
with live changes bypassed, investigate playback, looping, audio interaction, and
other concurrent work instead of assuming sendParameters is the cause.

The first 64 actual updates include before/after markers and numeric values.
Native faults and background exceptions cannot be caught by a main-queue
Objective-C @try block. The final app-log marker is a boundary, not a stack trace.

References: [immediate parameter updates](https://developer.apple.com/documentation/corehaptics/chhapticpatternplayer/sendparameters(_:attime:)),
[haptics-only playback](https://developer.apple.com/documentation/corehaptics/chhapticengine/playshapticsonly).
