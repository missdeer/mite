#!/bin/bash
# Run from the repository root in a macOS GUI login session with Metal available.
# Uses the system clipboard temporarily and restores its contents on completion.
set -euo pipefail

WORK="$PWD/tmp/macos-clipboard-tests"
mkdir -p "$WORK"
clang -fobjc-arc -c tests/macos/ClipboardBridge.m -o "$WORK/bridge.o"
swiftc -module-cache-path "$PWD/tmp/swift-module-cache" \
    -import-objc-header tests/macos/ClipboardBridge.h \
    src/macos/app/KeyInput.swift src/macos/app/TerminalView.swift \
    tests/macos/ClipboardTests.swift "$WORK/bridge.o" \
    -framework AppKit -framework Metal -framework QuartzCore \
    -o "$WORK/clipboard-tests"
"$WORK/clipboard-tests"
