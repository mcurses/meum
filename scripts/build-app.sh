#!/bin/sh
# Builds the meum app and assembles build/meum.app:
#   Contents/MacOS/meum                 the app (App/ SwiftPM package, links GhosttyKit statically)
#   Contents/Info.plist                bundle id io.github.mcurses.meum
#   Contents/Resources/ghostty         Ghostty's resources (shell-integration, themes) = GHOSTTY_RESOURCES_DIR
#   Contents/Resources/terminfo        compiled terminfo, the SIBLING of ghostty/ (libghostty derives TERMINFO
#                                      as dirname(GHOSTTY_RESOURCES_DIR)/terminfo at spawn)
#   Contents/Resources/bin/zmx         the bundled zmx
#   Contents/Resources/bin/meum         the `meum` CLI (root package); bin/ is prepended to PATH in every tab
#   Contents/Resources/bin/meum-hook    the Claude Code hook forwarder (Resources/bin/meum-hook)
#   Contents/Resources/meum.icns       the app icon (Resources/icon/, made from meum-1024.png)
#   Contents/Frameworks/libMeumKit.dylib the widget interface, shared with every widget library at run time
# Run scripts/setup.sh first (it short-circuits when vendor/ is ready).
#
# Usage: scripts/build-app.sh [debug|release]   (default release)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/meum.app"
GHOSTTY="$ROOT/vendor/ghostty"
ZMX="$ROOT/vendor/zmx/zig-out/bin/zmx"

[ -f "$GHOSTTY/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a" ] || {
  echo "build-app: GhosttyKit missing; run scripts/setup.sh" >&2; exit 1; }
[ -x "$ZMX" ] || { echo "build-app: zmx missing; run scripts/setup.sh" >&2; exit 1; }

echo "build-app: swift build -c $CONFIG (App/)"
(cd "$ROOT/App" && swift build -c "$CONFIG" --product MeumApp)
BIN="$(cd "$ROOT/App" && swift build -c "$CONFIG" --product MeumApp --show-bin-path)/MeumApp"
echo "build-app: swift build -c $CONFIG --product meum (CLI)"
(cd "$ROOT" && swift build -c "$CONFIG" --product meum)
CLI="$(cd "$ROOT" && swift build -c "$CONFIG" --product meum --show-bin-path)/meum"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/meum"
cp "$(dirname "$BIN")/libMeumKit.dylib" "$APP/Contents/Frameworks/libMeumKit.dylib"
# the build's rpaths point into .build; the bundle finds MeumKit next to itself
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/meum" 2>/dev/null || true
cp "$ZMX" "$APP/Contents/Resources/bin/zmx"
cp "$CLI" "$APP/Contents/Resources/bin/meum"
cp "$ROOT/Resources/icon/meum.icns" "$APP/Contents/Resources/meum.icns"
cp "$ROOT/Resources/bin/meum-hook" "$APP/Contents/Resources/bin/meum-hook"
chmod 755 "$APP/Contents/Resources/bin/meum-hook"
# Ghostty's resources without the docs; terminfo as the sibling directory
mkdir -p "$APP/Contents/Resources/ghostty"
cp -R "$GHOSTTY/zig-out/share/ghostty/shell-integration" "$APP/Contents/Resources/ghostty/"
cp -R "$GHOSTTY/zig-out/share/ghostty/themes" "$APP/Contents/Resources/ghostty/"
cp -R "$GHOSTTY/zig-out/share/terminfo" "$APP/Contents/Resources/terminfo"

VERSION="${MEUM_VERSION:-0.1.0}"
BUILD="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.mcurses.meum</string>
  <key>CFBundleName</key><string>meum</string>
  <key>CFBundleDisplayName</key><string>meum</string>
  <key>CFBundleExecutable</key><string>meum</string>
  <key>CFBundleIconFile</key><string>meum</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

# Signing. An ad-hoc signature has no identity, so macOS pins privacy grants (screen recording,
# accessibility) to the binary's hash and drops them on every rebuild. A stable certificate makes the
# designated requirement `identifier "io.github.mcurses.meum" and certificate leaf = H"…"`, which
# survives rebuilds. Default: Max's local self-signed certificate; MEUM_SIGN_IDENTITY overrides it
# (later a "Developer ID Application: …" identity for builds shared with others). Falls back to ad-hoc
# when the identity is missing.
SIGN_IDENTITY="${MEUM_SIGN_IDENTITY:-Max Studanski Local Code Signing}"
if [ "$SIGN_IDENTITY" != "-" ] && ! security find-identity -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
  echo "build-app: signing identity \"$SIGN_IDENTITY\" not found; signing ad-hoc (privacy grants won't survive rebuilds)" >&2
  SIGN_IDENTITY="-"
fi
sign() { codesign --force --sign "$SIGN_IDENTITY" "$@"; }
sign "$APP/Contents/Resources/bin/zmx"
sign "$APP/Contents/Resources/bin/meum"
sign "$APP/Contents/Frameworks/libMeumKit.dylib"
sign --identifier io.github.mcurses.meum "$APP"
codesign --verify --strict "$APP"
echo "build-app: signed with \"$SIGN_IDENTITY\""
echo "build-app: $APP"
