#!/bin/sh
# Builds a widget package (a SwiftPM dynamic library product that links MeumKit) and installs it as
# <widgets dir>/<product>.meumwidget/{manifest.json, lib<product>.dylib}, then asks a running meum to reload.
#
# Usage: scripts/build-widget.sh <package dir> <product> [id] [display name] [scope: global|workspace|tile]
#   MEUM_WIDGETS_DIR   install there instead of ~/.local/share/meum/widgets
#   MEUM_SOCKET        the meum to reload (default the user's)
set -eu
PKG="$(cd "$1" && pwd)"; PRODUCT="$2"; ID="${3:-$PRODUCT}"; NAME="${4:-$PRODUCT}"; SCOPE="${5:-global}"
DIR="${MEUM_WIDGETS_DIR:-$HOME/.local/share/meum/widgets}"
(cd "$PKG" && swift build -c release --product "$PRODUCT")
LIB="$(cd "$PKG" && swift build -c release --product "$PRODUCT" --show-bin-path)/lib$PRODUCT.dylib"
DEST="$DIR/$PRODUCT.meumwidget"
mkdir -p "$DEST"
cp "$LIB" "$DEST/lib$PRODUCT.dylib"
# Signed with the Developer ID when there is one: meum then trusts the build by its team (widgetTeamIDs), not
# only in developer mode. MEUM_WIDGET_SIGN_IDENTITY overrides; "-" signs ad-hoc.
IDENTITY="${MEUM_WIDGET_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$DEST/lib$PRODUCT.dylib" >/dev/null 2>&1 \
  || codesign --force --sign - "$DEST/lib$PRODUCT.dylib" >/dev/null 2>&1 || true
printf '{"id": "%s", "displayName": "%s", "library": "lib%s.dylib", "scope": "%s"}\n' "$ID" "$NAME" "$PRODUCT" "$SCOPE" > "$DEST/manifest.json"
echo "build-widget: installed $DEST"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/build/meum.app/Contents/Resources/bin/meum"
[ -x "$CLI" ] || CLI="$(command -v meum || true)"
[ -n "$CLI" ] && "$CLI" ${MEUM_SOCKET:+--socket "$MEUM_SOCKET"} widget reload 2>/dev/null || echo "build-widget: meum not running (or no CLI); it loads the widget on the next start"
