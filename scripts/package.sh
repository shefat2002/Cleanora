#!/bin/bash
# Archive + sign + notarize Cleanora for direct distribution (Developer ID).
# App Store is out of scope by design — the app is deliberately non-sandboxed.
#
# Required:
#   CODESIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE      name of a notarytool keychain profile
#                       (create once: xcrun notarytool store-credentials NOTARY_PROFILE)
#
# Usage: CODESIGN_IDENTITY="..." NOTARY_PROFILE="..." ./scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY (Developer ID Application)}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"

BUILD_DIR="build"
APP_PATH="$BUILD_DIR/Cleanora.app"
ZIP_PATH="$BUILD_DIR/Cleanora.zip"

echo "==> Archiving"
xcodebuild -project Cleanora.xcodeproj -scheme Cleanora \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/dd" build

APP_SOURCE=$(find "$BUILD_DIR/dd/Build/Products/Release" -name "Cleanora.app" -maxdepth 1)
mkdir -p "$BUILD_DIR"
rm -rf "$APP_PATH"
cp -R "$APP_SOURCE" "$APP_PATH"

echo "==> Codesigning (hardened runtime, deep)"
codesign --force --deep --sign "$CODESIGN_IDENTITY" \
  --options runtime --timestamp \
  "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute "$APP_PATH" || true

echo "==> Notarizing"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP_PATH"

echo "==> Gate check"
spctl --assess --type execute "$APP_PATH"

echo "==> Done: $APP_PATH (notarized + stapled)"
