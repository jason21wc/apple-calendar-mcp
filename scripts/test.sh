#!/bin/bash
# Run the Swift test suite.
#
# WHY THIS WRAPPER EXISTS
# `import Testing` needs no package dependency on Swift 6.3, but on a machine with only the
# Command Line Tools installed, Testing.framework sits under <developer dir>/Library/Developer
# and SwiftPM does not put it on the compiler's framework search path or on the test bundle's
# rpath. Plain `swift test` then fails with "no such module 'Testing'", and after that with a
# dyld error for Testing.framework and then for lib_TestingInterop.dylib.
#
# XCTest is not an alternative here: the Command Line Tools ship no XCTest.swiftmodule at
# all, so swift-testing is the only test framework available without a full Xcode install.
#
# The paths are derived from `xcode-select -p` rather than hardcoded, so this works for both
# a Command Line Tools and a full Xcode installation. When the framework is already on the
# default search path (Xcode), the extra flags are harmless and are skipped anyway.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
INTEROP="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"

EXTRA=""
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
    EXTRA="-Xswiftc -F -Xswiftc $FRAMEWORKS -Xlinker -rpath -Xlinker $FRAMEWORKS"
    if [ -f "$INTEROP/lib_TestingInterop.dylib" ]; then
        EXTRA="$EXTRA -Xlinker -rpath -Xlinker $INTEROP"
    fi
else
    echo "note: Testing.framework not found under $FRAMEWORKS; relying on the default search path"
fi

# Word splitting of $EXTRA is intended: it is a flag list, not a path.
# shellcheck disable=SC2086
exec swift test $EXTRA "$@"
