#!/bin/sh
# Builds a meum release that opens on other people's Macs without Gatekeeper warnings:
#   1. scripts/build-app.sh (release config, version from the argument)
#   2. re-sign every Mach-O in the bundle with the Developer ID, hardened runtime and a secure timestamp
#      (the app itself with scripts/entitlements.plist)
#   3. notarize the app and staple the ticket to it
#   4. put it in a DMG (with an /Applications link), sign, notarize and staple the DMG
# Output: build/release/meum-<version>-<arch>.dmg (and the stapled build/release/meum.app).
#
# Usage: scripts/release.sh <version>          e.g. scripts/release.sh 0.2.0
#   MEUM_RELEASE_IDENTITY   signing identity (default: the "Developer ID Application" in the keychain)
#   MEUM_NOTARY_PROFILE     notarytool keychain profile (default: meum; see `xcrun notarytool store-credentials`)
#   MEUM_SKIP_NOTARIZE=1    sign only (for a quick local check of the hardened-runtime build)
#
# Local everyday builds stay on scripts/build-app.sh with the self-signed identity: a Developer ID build is a
# different signer to macOS, so installing it over a local build asks for privacy grants again (once).
set -eu

VERSION="${1:?usage: scripts/release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
PROFILE="${MEUM_NOTARY_PROFILE:-meum}"
IDENTITY="${MEUM_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "release: no Developer ID Application identity in the keychain" >&2; exit 1; }
ARCH="$(uname -m)"
log() { echo "release: $*"; }

log "building $VERSION"
MEUM_VERSION="$VERSION" "$ROOT/scripts/build-app.sh" release
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$ROOT/build/meum.app" "$OUT/meum.app"
APP="$OUT/meum.app"

log "signing with \"$IDENTITY\""
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
# inside out: nested code first, the bundle last
sign "$APP/Contents/Resources/bin/zmx"
sign "$APP/Contents/Resources/bin/meum"
sign "$APP/Contents/Frameworks/libMeumKit.dylib"
sign --identifier io.github.mcurses.meum --entitlements "$ROOT/scripts/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
# every Mach-O must carry the Developer ID (notarization rejects anything else)
find "$APP" -type f | while read -r f; do
  if file "$f" | grep -q Mach-O && ! codesign -dv "$f" 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]"; then
    echo "release: not signed with a team: $f" >&2; exit 1
  fi
done

if [ "${MEUM_SKIP_NOTARIZE:-}" = 1 ]; then
  log "signed only (MEUM_SKIP_NOTARIZE=1): $APP"
  exit 0
fi

notarize() {
  log "notarizing $(basename "$1") (a few minutes)"
  out="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)" || true
  echo "$out" | tail -3
  if ! echo "$out" | grep -q "status: Accepted"; then
    id="$(echo "$out" | sed -n 's/^ *id: //p' | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    echo "release: notarization failed" >&2
    exit 1
  fi
}

ZIP="$OUT/meum-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"

DMG="$OUT/meum-$VERSION-$ARCH.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/meum.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "meum $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/release: /'
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/release: /'
log "done: $DMG ($ARCH only)"
