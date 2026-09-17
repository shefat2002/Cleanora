#!/bin/bash
# Export Cleanora as a distributable .dmg WITHOUT an Apple Developer account.
#
# No Developer ID cert exists here, so the app is ad-hoc signed: on machines
# that download it, Gatekeeper shows its one-time "unidentified developer"
# block. The DMG therefore ships a plain-text install note (the xattr /
# Open Anyway steps). Recipients who dislike that can build from source —
# the project is open source.
#
# Notarized distribution stays in scripts/package.sh (needs the paid program).
#
# Usage: ./scripts/export-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="build"
APP_PATH="$BUILD_DIR/Cleanora.app"
STAGE="$BUILD_DIR/dmg-stage"

echo "==> Building Release"
xcodebuild -project Cleanora.xcodeproj -scheme Cleanora \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/dd" build

APP_SOURCE=$(find "$BUILD_DIR/dd/Build/Products/Release" -name "Cleanora.app" -maxdepth 1)
mkdir -p "$BUILD_DIR"
rm -rf "$APP_PATH"
cp -R "$APP_SOURCE" "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/Cleanora-$VERSION.dmg"

echo "==> Ad-hoc codesigning (no Developer ID; keeps the signature self-consistent)"
codesign --force --deep --sign - --timestamp "$APP_PATH"
codesign --verify --strict "$APP_PATH"

echo "==> Staging DMG contents"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/INSTALL FIRST.txt" <<'EOF'
Cleanora — free, open-source macOS cleaner
https://github.com/shefat2002/Cleanora

Apple charges a yearly fee to "notarize" apps. Cleanora is free and has no
such subscription, so macOS shows ONE warning the first time you open it.
That warning means "Apple has not reviewed this app" — not that the app is
malware. The full source code is public if you prefer to build it yourself.

Install:
  1. Drag Cleanora onto the "Applications" folder shortcut in this window.
  2. Open your Applications folder and double-click Cleanora.
  3. If macOS says it cannot verify the app:
       - macOS 14 or earlier: right-click Cleanora -> Open -> Open.
       - macOS 15 or later: click Done, then open System Settings ->
         Privacy & Security, scroll to "Cleanora was blocked", click
         "Open Anyway", then "Open".
     This is only needed once.

Optional — skip the warning entirely, run this in Terminal, then open normally:
  xattr -dr com.apple.quarantine /Applications/Cleanora.app
EOF

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create -volname Cleanora -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE"

echo "==> Done: $DMG_PATH"
echo "    Unsigned distribution: recipients see Gatekeeper's one-time block;"
echo "    the DMG's INSTALL FIRST.txt walks them through it."
