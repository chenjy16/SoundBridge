#!/bin/bash
# SoundBridge Host Engine Launcher

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HOST_BINARY="$SCRIPT_DIR/.build/release/SoundBridgeHost"
DEBUG_BINARY="$SCRIPT_DIR/.build/debug/SoundBridgeHost"

echo "SoundBridge Host Engine Launcher"
echo "=============================="
echo ""

# Check if host binary exists
if [ -f "$HOST_BINARY" ]; then
    echo "Starting host engine (release build)..."
    "$HOST_BINARY"
elif [ -f "$DEBUG_BINARY" ]; then
    echo "Starting host engine (debug build)..."
    "$DEBUG_BINARY"
else
    echo "Error: Host binary not found!"
    echo "Please build first: swift build --configuration release"
    exit 1
fi
