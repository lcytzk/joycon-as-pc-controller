#!/bin/bash
set -e
cd "$(dirname "$0")/GyroKeyMapper"
swift build -c release
exec ./.build/release/GyroKeyMapper
