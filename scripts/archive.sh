#!/usr/bin/env bash
# Archives OMNIA and uploads it to App Store Connect for TestFlight.
#
# Run on a Mac with Xcode 26 or later, signed in to your Apple Developer account
# (Xcode › Settings › Accounts), after setting DEVELOPMENT_TEAM and OMNIA_BUNDLE_ID_PREFIX
# in Config/Signing.xcconfig.
#
#   ./scripts/archive.sh            archive + upload to TestFlight
#   ./scripts/archive.sh --no-upload   archive only (then use Xcode › Organizer)
set -euo pipefail

cd "$(dirname "$0")/.."
ARCHIVE_PATH="build/OMNIA.xcarchive"
EXPORT_PATH="build/export"

echo "› Resolving Swift packages (llama.cpp XCFramework, swift-jinja)…"
xcodebuild -resolvePackageDependencies -project OMNIA.xcodeproj -scheme OMNIA

echo "› Archiving (Release, generic iOS device)…"
xcodebuild archive \
  -project OMNIA.xcodeproj \
  -scheme OMNIA \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates

if [[ "${1:-}" == "--no-upload" ]]; then
  echo "✓ Archive ready at $ARCHIVE_PATH — open Xcode › Window › Organizer to distribute."
  exit 0
fi

echo "› Uploading to App Store Connect (TestFlight internal testing)…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates

echo "✓ Uploaded. The build appears in App Store Connect › TestFlight after processing (usually 5–20 minutes)."
