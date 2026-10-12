#!/usr/bin/env python3
"""Source-integrated haptics safety contract checks.
These are structural checks, not a Core Haptics runtime substitute."""
from pathlib import Path
s=Path("kit/host/sdl/platform_ui_ios.mm").read_text()
checks={
 "callbacks distinguish reset and stop": "g_rumble_reset_epoch.fetch_add" in s and "g_rumble_stop_epoch.fetch_add" in s,
 "reset reconciles on main queue": "dispatch_async(dispatch_get_main_queue(), ^{ rumble_process_latest(); });" in s,
 "engine epoch checked after player start": "startup_epoch == g_rumble_engine_notifications.load" in s,
 "player update checks epoch after send": "epoch == g_rumble_engine_notifications.load" in s,
 "foreground gating implemented": "g_rumble_app_active = false" in s and "g_rumble_app_active = true" in s,
 "asynchronous engine startup implemented": "startWithCompletionHandler:" in s,
 "bounded startup retries implemented": "g_rumble_start_failures" in s and ("retry_deadline" in s or "next_retry" in s),
 "single-owner drain implemented": "g_rumble_drain_scheduled.store(false" in s and "g_rumble_request_version.load" in s,
}
for name,ok in checks.items(): print(("PASS" if ok else "GAP ")+": "+name)
# Known unimplemented safety features are reported without hiding the gap.
assert checks["callbacks distinguish reset and stop"]
assert checks["reset reconciles on main queue"]
assert checks["engine epoch checked after player start"]
assert checks["player update checks epoch after send"]
print("PASS: implemented lifecycle contract assertions")
