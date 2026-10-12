#!/bin/bash
# Builds Pulso and wraps the executable into build/Pulso.app.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Pulso.app"

swift build -c "$CONFIG" --product Pulso
swift build -c "$CONFIG" --product pulso-fand
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/Pulso" "$APP/Contents/MacOS/Pulso"
cp Support/Info.plist "$APP/Contents/Info.plist"

# The fan helper and its installer travel inside the app, so that a copy installed
# from the disk image can set fan control up without the sources.
cp "$BIN/pulso-fand" "$APP/Contents/Helpers/pulso-fand"
cp scripts/install-fan-helper.sh scripts/uninstall-fan-helper.sh "$APP/Contents/Resources/"

# Ad-hoc signature: enough to run locally, and required on Apple Silicon.
# Nested code is signed before the bundle that seals it.
codesign --force --sign - "$APP/Contents/Helpers/pulso-fand"
codesign --force --sign - "$APP"

echo "$APP"
