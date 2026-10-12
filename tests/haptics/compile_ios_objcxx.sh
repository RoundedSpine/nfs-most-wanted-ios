#!/usr/bin/env bash
set -euo pipefail
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "Compiling actual Objective-C++ iOS integration with SDK: $SDK"
# Compile only; no proprietary game assets or full recompilation required.
xcrun --sdk iphoneos clang++ \
  -target arm64-apple-ios16.0 -std=c++20 -fobjc-arc \
  -fsyntax-only -Werror=return-type \
  -isysroot "$SDK" \
  -Ikit/host -Ikit/host/sdl -Ikit -Ikit/mods -Ikit/runtime \
  -Ibuild -Ibuild/generated -Ibuild/recomp/gen \
  kit/host/sdl/platform_ui_ios.mm
