#!/bin/sh
# Builds a meum release that opens on other people's Macs without Gatekeeper warnings:
#   1. scripts/setup.sh --release (the vendored Ghostty and zmx are exactly their pins and patches, and the build
#      outputs that ship are built from them), then
#      scripts/build-app.sh (release config, version from the argument), then scripts/api-smoke against that build
#   2. re-sign every Mach-O in the bundle with the Developer ID, hardened runtime and a secure timestamp
#      (the app itself with scripts/entitlements.plist)
#   3. notarize the app and staple the ticket to it
#   4. put it in a DMG (with an /Applications link), sign, notarize and staple the DMG
# Output: build/release/meum-<version>-<arch>.dmg (and the stapled build/release/meum.app).
# --publish adds one commit "meum <version>" with this build's files on top of the public repo's main (the
# private history is never pushed), pushes it, and creates the GitHub release v<version> with the DMG (what
# running copies update from). --notes FILE gives the release text, else GitHub generates it.
# --tag runs the same checks and the gate, then pushes that public commit and the tag v<version> on it, and builds
# nothing: GitHub Actions (.github/workflows/release.yml) builds, signs, notarizes and publishes from the tag, with
# docs/releases/<version>.md as the release text. --publish is the fallback that does all of it on this Mac (after a
# failed Actions run too: the public commit and tag already pushed are reused).
# --zmx-protocol-change lets --publish ship a zmx wire protocol other than the last public release's
# (scripts/zmx-protocol). --meumkit-break lets a MeumKit or control API change that is not an addition through
# (scripts/interface-diff).
# --no-gate publishes without a release gate (MEUM_RELEASE_GATE, below).
# --prebuilt signs and notarizes the build/meum.app that scripts/setup.sh --release, MEUM_VERSION=<version>
# MEUM_URL_SCHEME=1 scripts/build-app.sh release and scripts/api-smoke made from this same checkout just before
# (Actions: the build runs in steps without the signing secrets, only signing in a step with them).
#
# Usage: scripts/release.sh <version>          e.g. scripts/release.sh 0.2.0
#   MEUM_RELEASE_IDENTITY   signing identity (default: the "Developer ID Application" in the keychain)
#   MEUM_NOTARY_PROFILE     notarytool keychain profile (default: meum; see `xcrun notarytool store-credentials`)
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   notarize with these instead of the profile (Actions)
#   MEUM_RELEASE_GATE       with --publish: a local command that must succeed before publishing (it gets the
#                           commit as its argument); --publish refuses without one unless --no-gate
#   MEUM_SKIP_NOTARIZE=1    sign only (for a quick local check of the hardened-runtime build)
#
# Local everyday builds stay on scripts/build-app.sh with the self-signed identity: a Developer ID build is a
# different signer to macOS, so installing it over a local build asks for privacy grants again (once).
set -eu

VERSION="${1:?usage: scripts/release.sh <version> [--tag | --publish [--notes FILE]] [--zmx-protocol-change] [--meumkit-break] [--no-gate]}"
shift
PUBLISH=0
TAG=0
PREBUILT=0
NOTES=""
ZMX_CHANGE=0
MEUMKIT_BREAK=0
NO_GATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --tag) TAG=1 ;;
    --prebuilt) PREBUILT=1 ;;
    --notes) NOTES="${2:?--notes needs a file}"; shift ;;
    --zmx-protocol-change) ZMX_CHANGE=1 ;;
    --meumkit-break) MEUMKIT_BREAK=1 ;;
    --no-gate) NO_GATE=1 ;;
    *) echo "release: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$PUBLISH" = 1 ] && [ "$TAG" = 1 ] && { echo "release: --tag or --publish, not both" >&2; exit 2; }
if [ "$PUBLISH" = 1 ] || [ "$TAG" = 1 ]; then
  # refuse early, before minutes of notarizing: a release must come from a clean, pushed main
  [ -z "$(git -C "$(dirname "$0")/.." status --porcelain)" ] || { echo "release: the working tree is not clean" >&2; exit 1; }
  if gh release view "v$VERSION" -R mcurses/meum >/dev/null 2>&1; then echo "release: v$VERSION already exists" >&2; exit 1; fi
  if [ "$TAG" = 1 ] && [ -n "$(git -C "$(dirname "$0")/.." ls-remote --tags "${MEUM_PUBLIC_REMOTE:-github}" "refs/tags/v$VERSION")" ]; then
    echo "release: the tag v$VERSION is already on GitHub (its Actions run: gh run list -R mcurses/meum --workflow release.yml)" >&2; exit 1
  fi
  # a zmx wire protocol other than the last public release's orphans every running session on update day
  # (scripts/zmx-protocol says why); that takes a deliberate --zmx-protocol-change
  R="$(cd "$(dirname "$0")/.." && pwd)"
  git -C "$R" fetch -q "${MEUM_PUBLIC_REMOTE:-github}" main
  NOW_PROTO="$(grep -v '^#' "$R/scripts/zmx-protocol" | tr -d ' \n')"
  PUB_PROTO="$(git -C "$R" show "${MEUM_PUBLIC_REMOTE:-github}/main:scripts/zmx-protocol" 2>/dev/null | grep -v '^#' | tr -d ' \n')"
  PUB_PROTO="${PUB_PROTO:-1}"   # releases up to 0.4.0 predate the file; their zmx spoke 1
  # MeumKit additions only (and MINIMUM_MEUM bumped when it grew), no control API method or event dropped
  "$R/scripts/interface-diff" "$VERSION" "${MEUM_PUBLIC_REMOTE:-github}/main" $([ "$MEUMKIT_BREAK" = 1 ] && echo --allow-break) ||
    { echo "release: the interface check failed (scripts/interface-diff; --meumkit-break for a deliberate break)" >&2; exit 1; }
  if [ "$NOW_PROTO" != "$PUB_PROTO" ] && [ "$ZMX_CHANGE" != 1 ]; then
    echo "release: zmx wire protocol $PUB_PROTO -> $NOW_PROTO: updated copies could not reach their running sessions." >&2
    echo "release: read scripts/zmx-protocol; pass --zmx-protocol-change to release anyway" >&2
    exit 1
  fi
  # a local command that must succeed before publishing (a review the release needs, say); run from the checkout
  # it gets the commit being released as its argument; without one set, --publish refuses unless --no-gate
  if [ -n "${MEUM_RELEASE_GATE:-}" ]; then
    echo "release: gate: $MEUM_RELEASE_GATE"
    (cd "$R" && $MEUM_RELEASE_GATE "$(git -C "$R" rev-parse HEAD)") ||
      { echo "release: the release gate (MEUM_RELEASE_GATE) refused; not publishing" >&2; exit 1; }
  elif [ "$NO_GATE" = 1 ]; then
    echo "release: gate: none (--no-gate)"
  else
    echo "release: no release gate set (MEUM_RELEASE_GATE); set it, or pass --no-gate to publish without one" >&2
    exit 1
  fi
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# one version everywhere: the VERSION file, the plugin's manifest and the app built from them
[ "$(cat "$ROOT/VERSION")" = "$VERSION" ] || { echo "release: VERSION says $(cat "$ROOT/VERSION"), not $VERSION; change and commit it first" >&2; exit 1; }
PLUGIN_VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/plugin/.claude-plugin/plugin.json")"
[ "$PLUGIN_VERSION" = "$VERSION" ] || { echo "release: plugin/.claude-plugin/plugin.json says $PLUGIN_VERSION, not $VERSION; change and commit it first" >&2; exit 1; }
[ "$TAG" = 0 ] || [ -f "$ROOT/docs/releases/$VERSION.md" ] ||
  { echo "release: no release notes: write and commit docs/releases/$VERSION.md first" >&2; exit 1; }
OUT="$ROOT/build/release"
PROFILE="${MEUM_NOTARY_PROFILE:-meum}"
[ "$TAG" = 1 ] || IDENTITY="${MEUM_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ "$TAG" = 1 ] || [ -n "$IDENTITY" ] || { echo "release: no Developer ID Application identity in the keychain" >&2; exit 1; }
ARCH="$(uname -m)"
log() { echo "release: $*"; }

BUILT=$(git -C "$ROOT" rev-parse HEAD)   # the commit this release is built from (full id)

# The public repo has no shared history with the private one: each release is one commit on top of the public main,
# holding exactly the tree of $BUILT. Only that commit is pushed (a normal push). When the public main already holds
# this tree (pushed by --tag, its Actions run failed), it is reused.
public_commit() {
  REMOTE="${MEUM_PUBLIC_REMOTE:-github}"
  git -C "$ROOT" fetch -q "$REMOTE" main
  if [ "$(git -C "$ROOT" rev-parse "$REMOTE/main^{tree}")" = "$(git -C "$ROOT" rev-parse "$BUILT^{tree}")" ]; then
    PUBLIC=$(git -C "$ROOT" rev-parse "$REMOTE/main")
    log "public commit $PUBLIC already holds the tree of $BUILT"
    return
  fi
  PUBLIC=$(git -C "$ROOT" commit-tree "$BUILT^{tree}" -p "$REMOTE/main" -m "meum $VERSION

See the release notes: https://github.com/mcurses/meum/releases/tag/v$VERSION")
  log "public commit $PUBLIC (tree of $BUILT on top of $REMOTE/main)"
  git -C "$ROOT" push "$REMOTE" "$PUBLIC:refs/heads/main"
}

if [ "$TAG" = 1 ]; then
  public_commit
  git -C "$ROOT" push "$REMOTE" "$PUBLIC:refs/tags/v$VERSION"
  log "tagged v$VERSION; GitHub Actions builds and publishes it (gh run list -R mcurses/meum --workflow release.yml)"
  exit 0
fi

# the vendored dependencies go into the notarized app: refuse a tree edited after setup, or another checkout linked in
# (sources, and the build outputs that ship: zmx rebuilt every time, Ghostty unless setup's own build is recorded)
if [ "$PREBUILT" = 1 ]; then
  BUILT_VERSION="$(defaults read "$ROOT/build/meum.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
  [ "$BUILT_VERSION" = "$VERSION" ] || { echo "release: --prebuilt: build/meum.app is version '$BUILT_VERSION', not $VERSION" >&2; exit 1; }
  log "signing the prebuilt build/meum.app"
else
"$ROOT/scripts/setup.sh" --release || { echo "release: vendor/ghostty or vendor/zmx is not its pinned version and build (scripts/setup.sh --release)" >&2; exit 1; }
log "building $VERSION"
MEUM_VERSION="$VERSION" MEUM_URL_SCHEME=1 "$ROOT/scripts/build-app.sh" release
# every API method against the built app, isolated from the user's meum (state, widgets, zmx namespace)
log "api smoke test"
"$ROOT/scripts/api-smoke" || { echo "release: the API smoke test failed" >&2; exit 1; }
fi
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

notary() {
  if [ -n "${APPLE_ID:-}" ]; then
    xcrun notarytool "$@" --apple-id "$APPLE_ID" --team-id "${APPLE_TEAM_ID:?}" --password "${APPLE_APP_PASSWORD:?}"
  else
    xcrun notarytool "$@" --keychain-profile "$PROFILE"
  fi
}
notarize() {
  log "notarizing $(basename "$1") (a few minutes)"
  out="$(notary submit "$1" --wait 2>&1)" || true
  echo "$out" | tail -3
  if ! echo "$out" | grep -q "status: Accepted"; then
    id="$(echo "$out" | sed -n 's/^ *id: //p' | head -1)"
    [ -n "$id" ] && notary log "$id" >&2 || true
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
log "Homebrew cask: version \"$VERSION\", sha256 \"$(shasum -a 256 "$DMG" | cut -d' ' -f1)\""

if [ "$PUBLISH" = 1 ]; then
  # The in-app updater reads GitHub's latest release and takes its "-<arch>.dmg" asset.
  public_commit
  if [ -n "$NOTES" ]; then
    gh release create "v$VERSION" "$DMG" -R mcurses/meum --target "$PUBLIC" --title "meum $VERSION" --notes-file "$NOTES"
  else
    gh release create "v$VERSION" "$DMG" -R mcurses/meum --target "$PUBLIC" --title "meum $VERSION" --generate-notes
  fi
fi
