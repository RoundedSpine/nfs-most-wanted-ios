#!/usr/bin/env bash
set -euo pipefail

# GitHub Actions entry point for the iOS build.
# This intentionally keeps signing outside CI. The resulting .app/IPA can
# subsequently be signed with the user's own Apple/SideStore workflow.
BUILD_TYPE="${1:-Release}"

echo "Building NFS Most Wanted iOS ($BUILD_TYPE)"
./ios-build.sh "$BUILD_TYPE"
