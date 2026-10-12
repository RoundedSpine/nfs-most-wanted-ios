#!/usr/bin/env python3
"""Apply the UIKit rumble cleanup to kit/host/sdl/platform_ui_ios.mm.
Run from the repository root: python3 apply_haptics_cleanup.py
"""
from pathlib import Path
import sys

path = Path('kit/host/sdl/platform_ui_ios.mm')
if not path.is_file():
    sys.exit(f'ERROR: {path} not found; run from repository root')
s = path.read_text(encoding='utf-8')
original = s
replacements = [
('UIImpactFeedbackGenerator *g_tap_generator;',
 'UIImpactFeedbackGenerator *g_tap_generator;\nUIImpactFeedbackGenerator *g_rumble_impact_generator; // main-queue owned'),
('// Haptics: a light impact tick for on-screen control presses, and a Core\n// Haptics continuous player standing in for game rumble on a device with no\n// controller. Both must run on the main thread.',
 '// Haptics: UIKit impacts for on-screen controls and (by default) gameplay\n// rumble. The legacy continuous Core Haptics player remains for A/B testing.\n// UIKit objects are accessed only on the main queue.'),
('// CI may build a diagnostic IPA with device Core Haptics disabled.\n// Keep controller rumble, UI tap feedback, and the crash monitor unchanged.',
 '// Diagnostic switch disables gameplay device haptics (UIKit or Core Haptics).\n// Controller rumble, UI tap feedback, and crash monitoring are unchanged.'),
("    // UIKit's impact generator provides discrete pulses, not continuous rumble.\n    // Throttle the game-thread requests before dispatching to the main queue;\n    // never construct or message a CHHapticAdvancedPatternPlayer in this mode.",
 '    // UIKit impacts are discrete rather than continuous rumble.\n    // Rate-limit requests before dispatch; UIKit remains main-queue owned.\n    // This path never messages a CHHapticAdvancedPatternPlayer.'),
('                static UIImpactFeedbackGenerator *generator = nil;\n                if (!generator)\n                    generator = [[UIImpactFeedbackGenerator alloc]\n                        initWithStyle:UIImpactFeedbackStyleMedium];\n                [generator impactOccurredWithIntensity:intensity];\n                ios_diagnostic("rumble UIKit impact dispatched");',
 '                if (!g_rumble_impact_generator)\n                    g_rumble_impact_generator = [[UIImpactFeedbackGenerator alloc]\n                        initWithStyle:UIImpactFeedbackStyleMedium];\n                [g_rumble_impact_generator impactOccurredWithIntensity:intensity];'),
('#endif // NFSMW_DISABLE_DEVICE_CORE_HAPTICS\n}',
 '#endif // gameplay device haptics\n}'),
]
for old, new in replacements:
    if old not in s:
        sys.exit('ERROR: expected code not found; no changes made.\nMissing:\n'+old[:200])
    if s.count(old) != 1:
        sys.exit('ERROR: expected exactly one occurrence; no changes made: '+old[:100])
    s = s.replace(old, new, 1)
if s == original:
    sys.exit('Nothing to change')
backup = path.with_suffix(path.suffix + '.before-haptics-cleanup')
if backup.exists():
    sys.exit(f'ERROR: backup already exists: {backup}')
backup.write_text(original, encoding='utf-8')
path.write_text(s, encoding='utf-8')
print(f'Updated {path}\nBackup: {backup}\nApplied {len(replacements)} cleanup edits.')
