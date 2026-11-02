#!/bin/sh
# Builds the spike host app from app/main.swift against GhosttyKit.xcframework (no Xcode project).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
XCF="$HERE/vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"
mkdir -p "$HERE/build"
swiftc -O -swift-version 5 \
  -I "$XCF/Headers" \
  "$HERE/app/main.swift" \
  "$XCF/libghostty-internal.a" \
  -lc++ \
  -framework AppKit -framework Metal -framework QuartzCore -framework CoreText \
  -framework CoreGraphics -framework IOSurface -framework Carbon -framework CoreVideo \
  -framework UniformTypeIdentifiers -framework GameController \
  -o "$HERE/build/GhosttyZmxSpike"
echo "built $HERE/build/GhosttyZmxSpike"
