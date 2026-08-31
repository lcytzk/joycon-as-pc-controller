#!/bin/bash
set -e
cd "$(dirname "$0")/GyroKeyMapper"
swift build -c release
nohup ./.build/release/GyroKeyMapper > /tmp/GyroKeyMapper.log 2>&1 &
echo "GyroKeyMapper started in background (pid $!), logs at /tmp/GyroKeyMapper.log"
