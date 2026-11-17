#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ASCEND_ROOT"
mkdir -p target/native-tests target/swift-module-cache
xcrun swiftc -O -warnings-as-errors -swift-version 5 -parse-as-library \
  -module-cache-path target/swift-module-cache -target arm64-apple-macosx13.0 \
  native/Sources/Models.swift native/Sources/Localization.swift native/Sources/English.swift \
  native/tests/RoutineTests.swift -o target/native-tests/RoutineTests
target/native-tests/RoutineTests
python3 native/tests/routine_bridge.py
