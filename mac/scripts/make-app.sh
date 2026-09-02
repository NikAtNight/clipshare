#!/bin/bash
# Builds ClipShare in release mode and packages it as a .app bundle so it
# runs as a real menu bar app with its own Keychain identity.
#
# SIGN_IDENTITY overrides the codesign identity. Defaults to the local
# self-signed "Talix Dev Signing" identity, falling back to ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building (release)..."
swift build -c release

APP="build/ClipShare.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ClipShare "$APP/Contents/MacOS/ClipShare"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

SIGN_ID="${SIGN_IDENTITY:-Talix Dev Signing}"
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if [[ "$IDENTITIES" == *"$SIGN_ID"* ]]; then
    codesign --force --sign "$SIGN_ID" --identifier app.talix.clipshare "$APP"
    echo "Signed with $SIGN_ID"
else
    codesign --force --sign - --identifier app.talix.clipshare "$APP"
    echo "Signed ad-hoc (identity '$SIGN_ID' not found)"
fi

echo "Built $APP"
echo "Run: open $APP"
