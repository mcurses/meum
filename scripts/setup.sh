#!/bin/sh
# Vendors and builds the two native dependencies of the meum app at pinned versions:
#   vendor/ghostty  Ghostty v1.4.0 -> macos/GhosttyKit.xcframework + zig-out/share/{ghostty,terminfo}
#   vendor/zmx      zmx 0.8.1      -> zig-out/bin/zmx
# Both are gitignored. Each step short-circuits when its output already exists (a symlink to an existing
# checkout is fine). Needs: git, zig 0.17, Xcode with the Metal toolchain
# (`xcodebuild -downloadComponent MetalToolchain`, once per machine).
#
# Usage: scripts/setup.sh [--force]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"

GHOSTTY_URL="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_TAG="v1.4.0"
GHOSTTY_COMMIT="83fb95624b0439ee660c2679b43b38c8b63769cd"

ZMX_URL="https://github.com/neurosnap/zmx.git"
ZMX_COMMIT="d6dc347"   # version 0.8.1

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$VENDOR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "setup: missing tool: $1" >&2; exit 1; }; }

ghostty_ready() {
  [ -f "$VENDOR/ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a" ] &&
  [ -d "$VENDOR/ghostty/zig-out/share/ghostty/shell-integration" ] &&
  [ -d "$VENDOR/ghostty/zig-out/share/terminfo" ]
}

if [ $FORCE = 0 ] && ghostty_ready; then
  echo "setup: ghostty ready ($VENDOR/ghostty)"
else
  need git; need zig; need xcodebuild
  if [ ! -d "$VENDOR/ghostty/.git" ]; then
    git clone --depth 1 --branch "$GHOSTTY_TAG" "$GHOSTTY_URL" "$VENDOR/ghostty"
  fi
  HEAD="$(git -C "$VENDOR/ghostty" rev-parse HEAD)"
  if [ "$HEAD" != "$GHOSTTY_COMMIT" ]; then
    echo "setup: vendor/ghostty is at $HEAD, expected $GHOSTTY_COMMIT ($GHOSTTY_TAG)" >&2
    exit 1
  fi
  if ! xcrun -f metal >/dev/null 2>&1; then
    echo "setup: the Metal toolchain is missing; run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  # The flags Ghostty's macos/AGENTS.md prescribes for the library its own Xcode project consumes; native =
  # this Mac's arch only. The same build installs share/ghostty (shell integration, themes) and the
  # compiled terminfo into zig-out/share.
  (cd "$VENDOR/ghostty" && zig build -Demit-macos-app=false -Demit-xcframework=true \
      -Dxcframework-target=native -Doptimize=ReleaseFast)
  ghostty_ready || { echo "setup: ghostty build did not produce the expected outputs" >&2; exit 1; }
fi

# meum carries a few zmx fixes as patches until they are merged upstream (scripts/patches/zmx/*.patch, each one a
# pull request candidate for neurosnap/zmx). zmx counts as ready only when its binary exists and every patch is in.
zmx_patched() {
  for p in "$ROOT"/scripts/patches/zmx/*.patch; do
    [ -e "$p" ] || continue
    git -C "$VENDOR/zmx" apply --reverse --check "$p" 2>/dev/null || return 1
  done
}
if [ $FORCE = 0 ] && [ -x "$VENDOR/zmx/zig-out/bin/zmx" ] && zmx_patched; then
  echo "setup: zmx ready ($VENDOR/zmx)"
else
  need git; need zig
  if [ ! -d "$VENDOR/zmx/.git" ]; then
    git clone "$ZMX_URL" "$VENDOR/zmx"
  fi
  git -C "$VENDOR/zmx" checkout -q "$ZMX_COMMIT"
  for p in "$ROOT"/scripts/patches/zmx/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$VENDOR/zmx" apply --reverse --check "$p" 2>/dev/null; then continue; fi
    git -C "$VENDOR/zmx" apply "$p" || { echo "setup: zmx patch $(basename "$p") does not apply" >&2; exit 1; }
    echo "setup: zmx patch $(basename "$p") applied"
  done
  (cd "$VENDOR/zmx" && zig build -Doptimize=ReleaseSafe)
fi

echo "setup: done"
