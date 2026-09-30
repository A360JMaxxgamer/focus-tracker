#!/usr/bin/env bash
# Builds a universal FocusTracker.app and packs it into dist/FocusTracker-<version>.dmg
# (drag-to-Applications layout) plus a .zip, for installing on another Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
APP="build/FocusTracker.app"
DIST="dist"
STAGE="build/dmg"
DMG="$DIST/FocusTracker-$VERSION.dmg"
ZIP="$DIST/FocusTracker-$VERSION.zip"

rm -rf "$STAGE" "$DMG" "$ZIP"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "FocusTracker $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$STAGE"

echo "Created $DMG"
echo "Created $ZIP"
lipo -archs "$APP/Contents/MacOS/FocusTracker"
