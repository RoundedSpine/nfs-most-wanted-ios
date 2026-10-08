
#!/bin/sh

# Set up the native NFS Most Wanted build environment.
# Usage:
#   ./setup.sh "/path/to/Need for Speed Most Wanted"
#   ./setup.sh "/path/to/Need for Speed Most Wanted" --check-only

set -eu

cd "$(dirname "$0")"

# This project requires an Apple Silicon Mac.
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: This port needs an Apple Silicon Mac." >&2
    echo "Detected architecture: $(uname -m)" >&2
    exit 1
fi

# Verify that Apple's command-line development tools are installed.
if ! xcode-select -p >/dev/null 2>&1; then
    echo "ERROR: Xcode Command Line Tools are required." >&2
    echo "Run: xcode-select --install" >&2
    exit 1
fi

# Find a native Python 3.11 or newer.
PYTHON=""

for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" -c '
import platform
import sys
sys.exit(
    0 if sys.version_info >= (3, 11)
    and platform.machine() == "arm64"
    else 1
)' >/dev/null 2>&1; then
            PYTHON="$candidate"
            break
        fi
    fi
done

# If native Python is unavailable, install the project's pinned Python.
if [ -z "$PYTHON" ]; then
    CACHE="$HOME/Library/NFSMW-Native-Setup"
    PBS="$CACHE/python"
    ARCHIVE="$CACHE/python.tar.gz"

    URL="https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.12.15%2B20261003-aarch64-apple-darwin-install_only.tar.gz"
    CHECKSUM="316a463172740e71d8dca1f2730784e325f3f720941137b5d674d5801a632213"

    mkdir -p "$CACHE"

    if [ ! -x "$PBS/bin/python3.12" ]; then
        echo "Downloading the pinned Apple Silicon Python runtime..."

        if command -v curl >/dev/null 2>&1; then
            curl -fL "$URL" -o "$ARCHIVE"
        else
            echo "ERROR: curl is required to download Python." >&2
            exit 1
        fi

        if command -v shasum >/dev/null 2>&1; then
            ACTUAL_CHECKSUM="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
        else
            echo "ERROR: shasum is required to verify Python." >&2
            exit 1
        fi

        if [ "$ACTUAL_CHECKSUM" != "$CHECKSUM" ]; then
            echo "ERROR: Python archive checksum verification failed." >&2
            rm -f "$ARCHIVE"
            exit 1
        fi

        mkdir -p "$PBS"
        tar -xzf "$ARCHIVE" -C "$PBS" --strip-components=1
        rm -f "$ARCHIVE"
    fi

    PYTHON="$PBS/bin/python3.12"
fi

echo "Using Python:"
"$PYTHON" --version

# Make sure the source kit is present.
if [ ! -f "kit/tools/setup.py" ]; then
    echo "ERROR: kit/tools/setup.py was not found." >&2
    echo "Make sure the complete repository has been checked out." >&2
    exit 1
fi

# --check-only validates the game files without creating the build environment.
for argument in "$@"; do
    if [ "$argument" = "--check-only" ]; then
        exec "$PYTHON" tools/setup_kit/setup.py "$@"
    fi
done

# Create the Python virtual environment if needed.
if [ -x ".venv/bin/python" ]; then
    if ! .venv/bin/python -c '
import platform
import sys
sys.exit(
    0 if sys.version_info >= (3, 11)
    and platform.machine() == "arm64"
    else 1
)' >/dev/null 2>&1; then
        echo "Removing an incompatible Python virtual environment..."
        rm -rf .venv
    fi
fi

if [ ! -x ".venv/bin/python" ]; then
    echo "Creating the Python virtual environment..."
    "$PYTHON" -m venv .venv
fi

# Install the development requirements.
echo "Installing Python requirements..."

if ! .venv/bin/python -m pip install --disable-pip-version-check \
    -r kit/requirements-dev.txt; then
    echo "ERROR: Failed to install Python requirements." >&2
    exit 1
fi

# Run the original project setup with the supplied game folder and options.
echo "Running NFS Most Wanted setup..."
exec .venv/bin/python tools/setup_kit/setup.py "$@"
