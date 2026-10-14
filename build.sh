#!/bin/bash
# Builds WhatsAppBlur.app into ./build and signs it.
# A stable signing identity keeps the Accessibility permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/WhatsAppBlur.app"
IDENTITY="${CODESIGN_IDENTITY:-Apple Development: Raymond Lau (89PBA7F683)}"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/WhatsAppBlur "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "Signing identity not found, using ad-hoc signing (Accessibility must be re-granted after each build)"
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
