#!/bin/sh
set -eu
ASCEND_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ASCEND_ROOT"
./scripts/cargo.sh build --release --locked -p ascend-bridge
ASCEND_APP="$ASCEND_ROOT/dist/ASCEND.app"
mkdir -p "$ASCEND_APP/Contents/MacOS" "$ASCEND_APP/Contents/Resources" target/swift-module-cache
swiftc -O -warnings-as-errors -swift-version 5 -parse-as-library -module-cache-path target/swift-module-cache \
    -target arm64-apple-macosx13.0 -framework SwiftUI -framework AppKit -framework Charts -framework UserNotifications -framework AVFoundation -framework Vision -framework ImageIO \
    native/Sources/*.swift -o target/ASCEND-native
rm -f "$ASCEND_APP/Contents/MacOS/ascend"
# Replace inodes instead of truncating executable pages used by a running instance.
cp target/ASCEND-native "$ASCEND_APP/Contents/MacOS/.ASCEND.$$.tmp"
mv -f "$ASCEND_APP/Contents/MacOS/.ASCEND.$$.tmp" "$ASCEND_APP/Contents/MacOS/ASCEND"
cp target/release/ascend-engine "$ASCEND_APP/Contents/MacOS/.ascend-engine.$$.tmp"
mv -f "$ASCEND_APP/Contents/MacOS/.ascend-engine.$$.tmp" "$ASCEND_APP/Contents/MacOS/ascend-engine"
cp -R native/Resources/*.lproj "$ASCEND_APP/Contents/Resources/"
cp assets/Info.plist "$ASCEND_APP/Contents/Info.plist"
ASCEND_ICON=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' assets/Info.plist)
swift -module-cache-path target/swift-module-cache scripts/icon.swift target/ASCEND.iconset
iconutil -c icns target/ASCEND.iconset -o "$ASCEND_APP/Contents/Resources/$ASCEND_ICON"
rm -f "$ASCEND_APP/Contents/Resources/ASCEND.icns"
codesign --force --sign - "$ASCEND_APP/Contents/MacOS/ascend-engine"
codesign --force --deep --sign - "$ASCEND_APP"
echo "Готово: $ASCEND_APP"
