#!/bin/sh
# Packages a widget for the widget library (docs/design/widget-library.md) and, with --publish, releases it:
#   1. build the widget (or take a ready .meumwidget folder with --folder, e.g. one with a helper)
#   2. write its manifest with the version, sign every executable in it with the Developer ID
#   3. zip the .meumwidget folder and compute its sha256
#   4. --publish: a GitHub release <id>-v<version> on mcurses/meum-widgets with the zip, and the catalog entry
#      in catalog.json (committed and pushed in the meum-widgets clone)
# Without --publish it only writes build/widget-release/<product>.meumwidget.zip and a catalog entry with a
# file:// URL to build/widget-release/catalog.json, for testing an install against a local catalog.
#
# Usage:
#   scripts/release-widget.sh <package dir> <product> <id> <name> <scope> <version> "<description>" [--publish]
#   scripts/release-widget.sh --folder <dir.meumwidget> <version> "<description>" [--publish]
#     (the folder's manifest.json gives id, displayName, scope; its "helper" is kept)
# Env: MEUM_WIDGETS_REPO (default ~/code/meum-widgets), MEUM_WIDGETS_GH (default mcurses/meum-widgets),
#      MEUM_RELEASE_IDENTITY (default: the Developer ID Application in the keychain)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/widget-release"
REPO="${MEUM_WIDGETS_REPO:-$HOME/code/meum-widgets}"
GH="${MEUM_WIDGETS_GH:-mcurses/meum-widgets}"
IDENTITY="${MEUM_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "release-widget: no Developer ID Application identity" >&2; exit 1; }
log() { echo "release-widget: $*"; }
mkdir -p "$OUT"

if [ "${1:-}" = "--folder" ]; then
  SRC="$(cd "$2" && pwd)"; VERSION="$3"; DESC="$4"; PUBLISH="${5:-}"
  FOLDER_NAME="$(basename "$SRC")"
  STAGE="$OUT/$FOLDER_NAME"
  rm -rf "$STAGE"; ditto "$SRC" "$STAGE"; rm -f "$STAGE/disabled"
else
  PKG="$(cd "$1" && pwd)"; PRODUCT="$2"; ID="$3"; NAME="$4"; SCOPE="$5"; VERSION="$6"; DESC="$7"; PUBLISH="${8:-}"
  log "building $PRODUCT"
  (cd "$PKG" && swift build -c release --product "$PRODUCT" >/dev/null)
  LIB="$(cd "$PKG" && swift build -c release --product "$PRODUCT" --show-bin-path)/lib$PRODUCT.dylib"
  FOLDER_NAME="$PRODUCT.meumwidget"
  STAGE="$OUT/$FOLDER_NAME"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp "$LIB" "$STAGE/"
  printf '{"id": "%s", "displayName": "%s", "library": "lib%s.dylib", "scope": "%s"}\n' "$ID" "$NAME" "$PRODUCT" "$SCOPE" \
    > "$STAGE/manifest.json"
fi

# the manifest gets the version; id, name, scope and library come from it
VARS="$OUT/.manifest-vars"
python3 -I - "$STAGE/manifest.json" "$VERSION" > "$VARS" <<'PY'
import json, sys, shlex
p, v = sys.argv[1], sys.argv[2]
m = json.load(open(p)); m["version"] = v
json.dump(m, open(p, "w"), indent=2); open(p, "a").write("\n")
for k, n in (("ID", "id"), ("NAME", "displayName"), ("SCOPE", "scope"), ("LIBFILE", "library")):
    print(f"{k}={shlex.quote(str(m.get(n, '')))}")
print("HAS_HELPER=" + ("true" if m.get("helper") else "false"))
PY
. "$VARS"; rm -f "$VARS"
[ -n "$ID" ] && [ -f "$STAGE/$LIBFILE" ] || { echo "release-widget: manifest needs id and an existing library" >&2; exit 1; }
[ -f "$STAGE/libMeumKit.dylib" ] && { echo "release-widget: the widget must not bundle libMeumKit.dylib" >&2; exit 1; }

log "signing with \"$IDENTITY\""
find "$STAGE" -type f | while read -r f; do
  # keep entitlements the widget's build gave its executables (e.g. a Bun-compiled helper's JIT ones)
  if file "$f" | grep -q Mach-O; then
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$IDENTITY" "$f"
  fi
done
ARCHS="$(lipo -archs "$STAGE/$LIBFILE")"

ZIP="$OUT/$FOLDER_NAME.zip"
rm -f "$ZIP"
(cd "$OUT" && ditto -c -k --keepParent "$FOLDER_NAME" "$ZIP")
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
log "$ZIP  sha256 $SHA  archs $ARCHS"

TAG="$ID-v$VERSION"
if [ "$PUBLISH" = "--publish" ]; then
  URL="https://github.com/$GH/releases/download/$TAG/$FOLDER_NAME.zip"
  CATALOG="$REPO/catalog.json"
  [ -d "$REPO/.git" ] || { echo "release-widget: no clone at $REPO" >&2; exit 1; }
  git -C "$REPO" pull --ff-only -q
else
  URL="file://$ZIP"
  CATALOG="$OUT/catalog.json"
fi

python3 -I - "$CATALOG" <<PY
import json, os, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {"version": 1, "widgets": []}
e = {"id": "$ID", "displayName": "$NAME", "description": """$DESC""", "author": "Max Studanski", "scope": "$SCOPE",
     "version": "$VERSION", "apiVersion": "meum.v1", "archs": "$ARCHS".split(), "url": "$URL", "sha256": "$SHA",
     "helper": $( [ "$HAS_HELPER" = true ] && echo True || echo False )}
c["widgets"] = [w for w in c["widgets"] if w["id"] != e["id"]] + [e]
c["widgets"].sort(key=lambda w: w["displayName"].lower())
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False); open(p, "a").write("\n")
PY
log "catalog entry written to $CATALOG"

if [ "$PUBLISH" = "--publish" ]; then
  gh release create "$TAG" "$ZIP" --repo "$GH" --title "$NAME $VERSION" --notes "$DESC

sha256: $SHA"
  git -C "$REPO" add catalog.json
  git -C "$REPO" commit -q -m "$NAME $VERSION"
  git -C "$REPO" push -q
  log "published $TAG and updated the catalog"
fi
