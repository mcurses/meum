#!/bin/sh
# Builds meum from this checkout and installs it as /Applications/meum.app (or $MEUM_INSTALL_PATH).
# The new bundle is swapped in with one atomic exchange (renamex_np RENAME_SWAP): a meum that is running keeps
# finding its bundled zmx at every moment, so a tab that starts during the install still attaches. The running app
# keeps the old code until it restarts. The old bundle is kept, hidden, as .<name>.previous next to it until the next install
# (a meum still running from it keeps a valid path until then).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${MEUM_INSTALL_PATH:-/Applications/meum.app}"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "install: the working tree is not clean" >&2; exit 1; }
"$ROOT/scripts/build-app.sh"
NEW="$(dirname "$DEST")/.$(basename "$DEST").new"
OLD="$(dirname "$DEST")/.$(basename "$DEST").previous"   # hidden, so Spotlight and Launchpad don't list it
rm -rf "$NEW" "$OLD"
ditto "$ROOT/build/meum.app" "$NEW"
codesign --verify --strict "$NEW"
if [ -e "$DEST" ]; then
  /usr/bin/python3 -I -c 'import ctypes,sys
libc = ctypes.CDLL(None, use_errno=True)
if libc.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2) != 0:   # 2 = RENAME_SWAP
    sys.exit("install: swap failed: " + __import__("os").strerror(ctypes.get_errno()))' "$NEW" "$DEST"
  mv "$NEW" "$OLD"
else
  mv "$NEW" "$DEST"
fi
echo "install: $DEST is $(git -C "$ROOT" rev-parse --short HEAD); restart meum to run it"
