# iOS performance and bug-fix testing branch

This branch is an experimental development track. The known-playable `main` branch must remain unchanged until an individual change passes device testing and a reviewed pull request.

## FPS / frame-time overlay: implementation specification

- Display a small, toggleable, non-interactive overlay in the iOS host layer, above the Metal game view and below/away from touch controls.
- Use actual presented-frame timestamps from the renderer, not the game's 60 Hz simulation clock.
- Show FPS (rolling 1-second average), average frame time (ms), and 1% low FPS over a rolling sample window.
- Use a monotonic clock. Ignore samples when paused/backgrounded and reset statistics after resuming.
- Default OFF in release builds; enable via a debug setting or gesture that does not intercept gameplay.
- Avoid logging every frame; allow an optional once-per-5-second diagnostic line for captures.
- Keep instrumentation outside gameplay timing, simulation rate, and shader compilation paths.
- Measure GPU time separately only if reliable Metal command-buffer completion timestamps are available; label CPU/presented FPS distinctly.

## Device test matrix

1. iPhone 16 Pro Max: main menu, Quick Race, pursuit, Career, saves, pause/resume, incoming notifications.
2. iPad Pro M5: same tests, plus 60/120 Hz display behavior.
3. Compare 60-second runs at identical in-game settings, same track, weather, car, and camera.
4. Record median FPS, 1% low, p95 frame time, thermal state, and any graphics/audio/input regressions.

## Merge policy

- Build unsigned IPA with the existing `iOS Build` GitHub Action on this branch.
- Never cherry-pick or merge experiments into `main` without a passing CI build and real-device test.
- Keep changes small and independently reversible.
- Record each bug with reproduction steps, logs, expected/actual behavior, and the fix commit.

## Current status

Branch created. Overlay is specified but **not implemented or tested yet**. This document deliberately does not claim that FPS measurements are available.
