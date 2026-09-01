#!/bin/bash
set -e
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR/GyroKeyMapper"

BINARY=".build/release/GyroKeyMapper"
# Outside .build/ on purpose: that directory gets wiped whenever the build
# system or layout changes, which would orphan a running instance that this
# script can then no longer find to kill before starting a new one.
PID_FILE="$ROOT_DIR/GyroKeyMapper.pid"

# Stop whatever this script last started, so re-running it is a restart
# rather than piling up a second instance (each would fight the other for
# HID input and mouse/keyboard output).
if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE")"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null && ps -p "$OLD_PID" -o comm= | grep -q "GyroKeyMapper"; then
        echo "Stopping previous instance (pid $OLD_PID)..."
        kill "$OLD_PID"
        for _ in $(seq 1 20); do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi

if [ ! -f "$BINARY" ] || [ -n "$(find Sources Package.swift -type f -newer "$BINARY" 2>/dev/null)" ]; then
    echo "Source changed — building..."
    swift build -c release
else
    echo "No source changes since last build — skipping build."
fi

nohup "./$BINARY" > /tmp/GyroKeyMapper.log 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"
echo "GyroKeyMapper started in background (pid $NEW_PID), logs at /tmp/GyroKeyMapper.log"
