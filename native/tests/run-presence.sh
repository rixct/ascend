#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ASCEND_ROOT"
mkdir -p target/native-tests target/swift-module-cache
xcrun swiftc -O -warnings-as-errors -swift-version 5 -parse-as-library \
  -module-cache-path target/swift-module-cache -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Vision -framework ImageIO \
  native/Sources/Models.swift native/Sources/Localization.swift native/Sources/English.swift \
  native/Sources/PresenceGate.swift native/Sources/FacePresenceDetector.swift native/Sources/CameraPresenceCapture.swift native/Sources/PresenceMonitor.swift \
  native/tests/PresenceTests.swift -o target/native-tests/PresenceTests
target/native-tests/PresenceTests native/tests/fixtures/astronaut.png
