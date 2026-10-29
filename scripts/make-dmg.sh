#!/bin/bash
# Builds a Release MacSentry.app and packs it into dist/MacSentry-<version>.dmg. Only creates files.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project MacSentry.xcodeproj -scheme MacSentry -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet build

app="build/DerivedData/Build/Products/Release/MacSentry.app"
version=$(defaults read "$PWD/$app/Contents/Info.plist" CFBundleShortVersionString)
stage=$(mktemp -d "${TMPDIR:-/tmp}/macsentry-dmg.XXXXXX")
ditto "$app" "$stage/MacSentry.app"
ln -s /Applications "$stage/Applications"

mkdir -p dist
out="dist/MacSentry-$version.dmg"
[[ -e "$out" ]] && out="dist/MacSentry-$version-$(date +%Y%m%d%H%M%S).dmg"
hdiutil create -volname MacSentry -srcfolder "$stage" -fs HFS+ -format UDZO -quiet "$out"
codesign --verify --deep --strict "$app"
echo "$out"
