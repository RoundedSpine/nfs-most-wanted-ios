
from pathlib import Path

path = Path("kit/tools/build.py")

if not path.is_file():
    raise SystemExit(
        "ERROR: kit/tools/build.py was not found. "
        "Run this script from your repository root."
    )

source = path.read_text(encoding="utf-8")

changes = [
    (
        '    parser.add_argument("--no-install", action="store_true", help="Build the mobile app without installing it")',
        '    parser.add_argument("--unsigned", action="store_true", '
        'help="Build the real iOS app without Apple code signing or device installation")\n'
        '    parser.add_argument("--no-install", action="store_true", '
        'help="Build the mobile app without installing it")',
    ),
    (
        '    if args.target == "ios" and not args.stub and not args.team:',
        '    if args.target == "ios" and not args.stub and not args.team and not args.unsigned:',
    ),
    (
        '                extra = ["--", "CODE_SIGNING_ALLOWED=NO"] if args.stub else ["--", "-allowProvisioningUpdates"]',
        '                if args.unsigned or args.stub:\n'
        '                    extra = ["--", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]\n'
        '                else:\n'
        '                    extra = ["--", "-allowProvisioningUpdates"]',
    ),
    (
        '                if not args.stub and not args.no_install:',
        '                if not args.stub and not args.no_install and not args.unsigned:',
    ),
]

for old, new in changes:
    count = source.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: Expected one matching code section, found {count}.\n"
            f"Could not safely patch:\n{old}"
        )

backup = path.with_suffix(".py.before-unsigned")
backup.write_text(source, encoding="utf-8")

for old, new in changes:
    source = source.replace(old, new, 1)

path.write_text(source, encoding="utf-8")

print("SUCCESS: unsigned iOS build support added.")
print(f"Original backup: {backup}")
print(f"Updated file: {path}")
