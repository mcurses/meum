#!/bin/sh
# Launches build/meum.app isolated for a scripted check and prints its pid.
#   state dir   $MEUMT/state        (never ~/.local/state/meum)
#   debug dir   $MEUMT/dbg          (DebugControl: cmd, events.log, pid, window.id)
#   widgets     $MEUMT/widgets      (never ~/.local/share/meum/widgets)
#   zmx         ZMX_DIR=$TMPDIR/meumtest-zmx, session prefix "meumtest-" (never the user's zmx namespace)
# MEUMT defaults to build/test. Extra args go to the app (e.g. --frame 100,100,1400,850).
# Drive it with scripts/meumt (cmd, wait, shot, text). Stop it with `scripts/meumt quit` or kill <pid>.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEUMT="${MEUMT:-$ROOT/build/test}"
mkdir -p "$MEUMT/state" "$MEUMT/dbg"
rm -f "$MEUMT/dbg/events.log" "$MEUMT/dbg/pid" "$MEUMT/dbg/window.id" "$MEUMT/dbg/cmd"
ZD="${TMPDIR:-/tmp}"
ZD="${ZD%/}/meumtest-zmx"
mkdir -p "$ZD"
ZMX_DIR="$ZD" MEUM_ZMX_PREFIX=meumtest- MEUM_STATE_DIR="$MEUMT/state" MEUM_DEBUG_DIR="$MEUMT/dbg" \
  MEUM_WIDGETS_DIR="${MEUM_WIDGETS_DIR:-$MEUMT/widgets}" \
  MEUM_AUTOQUIT="${MEUM_AUTOQUIT:-600}" \
  "$ROOT/build/meum.app/Contents/MacOS/meum" "$@" >"$MEUMT/app.out" 2>&1 &
echo $!
