#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ASCEND_ROOT"
mkdir -p target/native-tests target/swift-module-cache
xcrun swiftc -O -warnings-as-errors -swift-version 5 -parse-as-library \
  -module-cache-path target/swift-module-cache -target arm64-apple-macosx13.0 \
  native/Sources/Models.swift native/Sources/Localization.swift native/Sources/English.swift \
  native/Sources/NotificationPlan.swift native/Sources/NotificationSenderProtocol.swift \
  native/tests/NotificationPlanTests.swift \
  -o target/native-tests/NotificationPlanTests
target/native-tests/NotificationPlanTests
