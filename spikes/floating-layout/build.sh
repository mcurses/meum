#!/bin/sh
# Builds build/FloatingLayout.app (the spike) and build/probe (the test helper).
set -e
cd "$(dirname "$0")"
APP=build/FloatingLayout.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/FloatingLayout" Sources/main.swift
swiftc -O -swift-version 5 -o build/probe probe.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.max.meum.floating-layout-spike</string>
  <key>CFBundleName</key><string>FloatingLayout</string>
  <key>CFBundleExecutable</key><string>FloatingLayout</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "built $APP and build/probe"
