#!/bin/bash
# Installs GoPro Card into /Applications, starts it, and optionally makes it
# start automatically at login.
set -euo pipefail

cd "$(dirname "$0")"

APP="GoPro Card.app"
TARGET="/Applications/$APP"

if [ ! -d "$APP" ]; then
    echo "==> Building first"
    ./build.sh
fi

echo "==> Stopping any running copy"
osascript -e 'quit app "GoPro Card"' >/dev/null 2>&1 || true
sleep 2

echo "==> Installing to $TARGET"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo "==> Starting"
open "$TARGET"

if [ "${1:-}" = "--login" ]; then
    echo "==> Enabling start at login"
    "$TARGET/Contents/MacOS/GoProCard" --enable-login
fi

echo
echo "Done. Plug in the camera; it will appear in /Volumes within a few seconds."
echo "Log: ~/Library/Logs/GoProCard.log"
