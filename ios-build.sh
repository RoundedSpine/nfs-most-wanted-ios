#!/bin/sh
# Build Need for Speed: Most Wanted for iOS/iPadOS using the native Metal renderer.
# Run on an Apple Silicon Mac after the normal setup/translation step.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON="$ROOT/.venv/bin/python"
if [ ! -x "$PYTHON" ]; then
    echo "Missing $PYTHON. Run ./setup.sh with your own NFS MW installation first." >&2
    exit 1
fi
if [ -z "${RECOMP_IOS_TEAM:-}" ] && [ -z "${1:-}" ]; then
    echo "Usage: RECOMP_IOS_TEAM=<Apple Team ID> ./ios-build.sh [build.py options]" >&2
    echo "   or: ./ios-build.sh <Apple Team ID> [build.py options]" >&2
    exit 2
fi
TEAM="${RECOMP_IOS_TEAM:-$1}"
if [ -z "${RECOMP_IOS_TEAM:-}" ]; then shift; fi
exec "$PYTHON" "$ROOT/kit/tools/build.py" --game-dir "$ROOT" --target ios --team "$TEAM" "$@"
