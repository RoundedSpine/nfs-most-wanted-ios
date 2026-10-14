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
# Preserve the documented positional team ID. All option-based invocations
# (including --unsigned and --team) go to the builder's one argument parser.
case "${1:-}" in
    ""|-*) ;;
    *) TEAM=$1; shift; set -- --team "$TEAM" "$@" ;;
esac
exec "$PYTHON" "$ROOT/tools/build.py" --target ios "$@"
