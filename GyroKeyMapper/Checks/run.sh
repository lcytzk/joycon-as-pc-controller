#!/bin/bash
# Runs the correctness checks. See main.swift for what they cover.
#
# Not `swift test`: XCTest ships with Xcode, and the Command Line Tools carry
# neither it nor the swift-testing library, so a SwiftPM test target can't build
# on a machine without a full Xcode. This compiles the pure-logic sources
# directly against the built JoyConSwift module instead — no framework, no
# change to the package layout.
set -e
cd "$(dirname "$0")/.."

swift build >/dev/null

OBJECTS=$(ls .build/*/debug/JoyConSwift.build/*.o 2>/dev/null | head -100)
if [ -z "$OBJECTS" ]; then
    echo "could not find the built JoyConSwift objects under .build — try 'swift build' first" >&2
    exit 1
fi

BINARY="$(mktemp -d)/checks"
# Only the sources with no AppKit or HID dependency: the config codec, the
# shared combine state, and the button state machine.
swiftc -O -o "$BINARY" \
    Checks/main.swift \
    Sources/GyroKeyMapper/Config.swift \
    Sources/GyroKeyMapper/CombineCoordinator.swift \
    Sources/GyroKeyMapper/ButtonSession.swift \
    $OBJECTS \
    -I .build/debug/Modules \
    -framework IOKit

"$BINARY"
