#!/bin/bash
set -euo pipefail

CONFIG="${1:-release}"
IDENTITY="${XFLOW_SIGN_IDENTITY:-XFlow Dev}"

swift build -c "$CONFIG" --product XFlow
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/XFlow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/XFlow" "$APP/Contents/MacOS/XFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The signing identity must stay stable forever: macOS binds Accessibility and
# Microphone grants to it, and a new identity means re-approving every permission.
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    echo "Signed with: $IDENTITY"
else
    echo "WARNING: signing identity '$IDENTITY' not found. Building unsigned."
    echo "Permission grants will reset on every rebuild. See README for setup."
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
