#!/usr/bin/env bash
# Builds FocusTracker.app into ./build and code-signs it.
# A stable signing identity (e.g. "Apple Development") keeps the Camera and
# Accessibility grants valid across rebuilds; ad-hoc signing ("-") does not.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/FocusTracker.app"

# UNIVERSAL=1 builds for Apple silicon and Intel.
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FocusTracker" "$APP/Contents/MacOS/FocusTracker"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"

codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${INSTALL:-0}" == "1" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/FocusTracker.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/FocusTracker.app"
fi
