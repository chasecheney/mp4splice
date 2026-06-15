#!/bin/bash
#
# Build, sign (Developer ID), notarize, and package MP4Splice as a stapled DMG
# for direct download (outside the App Store). Run on macOS with Xcode installed.
#
# One-time setup:
#   1. Have a "Developer ID Application" certificate in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → +).
#   2. Team ID (JTU6ZV6ZZF) is already set in ExportOptions-DeveloperID.plist.
#   3. Reuses the existing MP4TOOLS_NOTARY keychain profile (account-level, shared
#      with the MP4tools+ project). If it's not on this Mac, create it once:
#        xcrun notarytool store-credentials MP4TOOLS_NOTARY \
#          --apple-id "tom@cheney.com" --team-id "JTU6ZV6ZZF" \
#          --password "app-specific-password"
#
# Usage:
#   TEAM_ID=ABCDE12345 ./scripts/notarize-release.sh
#
set -euo pipefail

APP_NAME="MP4Splice"
SCHEME="MP4Splice"
PROJECT="MP4Splice/MP4Splice.xcodeproj"
# Reuses the existing account-level notary profile from the MP4tools+ project.
NOTARY_PROFILE="${NOTARY_PROFILE:-MP4TOOLS_NOTARY}"

BUILD="build"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
DMG="$APP_NAME.dmg"

cd "$(dirname "$0")/.."

echo "==> Cleaning"
rm -rf "$BUILD" "$DMG"

echo "==> Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" clean archive

echo "==> Exporting Developer ID-signed app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions-DeveloperID.plist \
  -exportPath "$EXPORT"

APP="$EXPORT/$APP_NAME.app"
[ -d "$APP" ] || { echo "Export failed: $APP not found"; exit 1; }

echo "==> Building DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" || true

echo "==> Done: $DMG (signed, notarized, stapled)"
