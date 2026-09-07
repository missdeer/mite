#!/bin/bash
# Run from the repository root in a macOS GUI login session with Metal available.
set -euo pipefail
WORK="$PWD/tmp/macos-scrollbar-tests"
mkdir -p "$WORK"
clang -fobjc-arc -c tests/macos/ClipboardBridge.m -o "$WORK/bridge.o"
swiftc -module-cache-path "$PWD/tmp/swift-module-cache" \
    -import-objc-header tests/macos/ClipboardBridge.h \
    src/macos/app/KeyInput.swift src/macos/app/TerminalView.swift \
    tests/macos/ScrollbarTests.swift "$WORK/bridge.o" \
    -framework AppKit -framework Metal -framework QuartzCore \
    -o "$WORK/scrollbar-tests"
"$WORK/scrollbar-tests"
