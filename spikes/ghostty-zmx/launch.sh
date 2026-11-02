#!/bin/sh
# Launch the spike app attached to zmx session spike-1; prints the pid.
. /Users/dev/code/meum/spikes/ghostty-zmx/env.sh
export SPIKE_CMD="$ZMX attach spike-1"
nohup "$SPIKE_DIR/build/GhosttyZmxSpike" >>"$SPIKE_OUT/app.stderr" 2>&1 &
echo $!
