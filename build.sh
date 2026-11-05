#!/bin/bash
# Builds "GoPro Card.app" from Sources/. No Xcode project, no third-party dependencies.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GoPro Card"
APP="$APP_NAME.app"
BUNDLE_ID="com.gopromount.goprocard"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
swiftc \
    -O \
    -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/GoProCard" \
    Sources/*.swift \
    -framework AppKit \
    -framework Network

echo "==> Bundling"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true

echo "==> Done: $(pwd)/$APP"
