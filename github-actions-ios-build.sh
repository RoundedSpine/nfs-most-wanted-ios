#!/usr/bin/env bash
set -euo pipefail

# GitHub Actions entry point for the iOS build.
# This intentionally keeps signing outside CI. The resulting .app/IPA can
# subsequently be signed with the user's own Apple/SideStore workflow.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Older callers pass the configuration positionally. Translate it once, then
# use the same option-based entry point as local builds and the CI workflow.
case "${1:-}" in
    Release|Debug) CONFIG=$1; shift; set -- --config "$CONFIG" "$@" ;;
esac
exec /bin/sh "$ROOT/ios-build.sh" --unsigned --no-install "$@"
