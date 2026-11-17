#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ASCEND_ROOT"
mkdir -p target/native-tests target/swift-module-cache
xcrun swiftc -O -warnings-as-errors -swift-version 5 -parse-as-library \
  -module-cache-path target/swift-module-cache -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Vision -framework ImageIO \
  native/Sources/EngineProcess.swift native/Sources/FocusGate.swift native/Sources/Store.swift native/Sources/Models.swift \
  native/Sources/Localization.swift native/Sources/English.swift native/Sources/ProfileAvatar.swift \
  native/Sources/PresenceGate.swift native/Sources/FacePresenceDetector.swift native/Sources/CameraPresenceCapture.swift native/Sources/PresenceMonitor.swift \
  native/Sources/Appearance.swift native/tests/StabilityTests.swift \
  -o target/native-tests/StabilityTests
target/native-tests/StabilityTests /usr/bin/python3 native/tests/FakeEngine.py target/ASCEND.iconset/icon_256x256.png
python3 native/tests/bridge_smoke.py
