#!/bin/bash
# Builds Pulso.app and packs it into build/Pulso-<version>.dmg, next to a shortcut
# to /Applications and a short note on opening an app that is not notarized.
# Usage: scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build-app.sh release >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DMG="build/Pulso-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto keeps the signature and the extended attributes intact.
ditto build/Pulso.app "$STAGE/Pulso.app"
ln -s /Applications "$STAGE/Applications"
cp Support/LEEME.txt "$STAGE/Léeme.txt"

rm -f "$DMG"
hdiutil create -volname "Pulso $VERSION" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"

echo "$DMG"
