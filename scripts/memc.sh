#!/bin/bash

set -e

SCRIPT_DIR="$( realpath -sm "$( dirname "${BASH_SOURCE[0]}" )" )"
source "$SCRIPT_DIR"/config.sh

echo "Sanitizing port 11211..."
# Stop the default system systemd service if it exists
sudo systemctl stop memcached 2>/dev/null || true

# Forcefully kill whatever process is holding port 11211 (root-level eviction)
if command -v fuser &>/dev/null; then
    sudo fuser -k 11211/tcp 2>/dev/null || true
else
    # Fallback if fuser isn't installed
    sudo pkill -9 -f memcached 2>/dev/null || true
fi

# Give the OS a split second to completely release the socket
sleep 0.5

# Kill any stale registry session. Deliberately NOT $TMUX_SESSION: that is
# where the experiment windows live, and on the registry machine those are the
# same machine.
tmux kill-session -t "$REGISTRY_SESSION" 2>/dev/null || true

echo "Spawning isolated tmux registry..."
tmux new-session -d -s "$REGISTRY_SESSION" -n "memc"

# Pass LD_PRELOAD explicitly inside the window execution string using single quotes 
# to protect paths from early shell expansion, and bind to 0.0.0.0
tmux send-keys -t "$REGISTRY_SESSION:memc" "LD_PRELOAD=$SCRIPT_DIR/libreparent.so memcached -p 11211 -l 0.0.0.0 -u $USER -c 8192 -b 2048" C-m