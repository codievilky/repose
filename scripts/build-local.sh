#!/bin/bash
set -euo pipefail

# Build a separate local app using Command Line Tools (full Xcode is optional).
# LOCAL_BUILD excludes the upstream updater and its Sparkle dependency.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Keep generated app bundles outside iCloud-managed Documents during signing.
BUILD_DIR="${REPOSE_BUILD_DIR:-${TMPDIR:-/tmp/}repose-ring-build}"
APP_PATH="$BUILD_DIR/Repose Ring.app"
SDK_PATH="${REPOSE_SDK_PATH:-$(xcrun --show-sdk-path)}"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$BUILD_DIR/module-cache"
swiftc -swift-version 5 -parse-as-library -O -D LOCAL_BUILD \
    -sdk "$SDK_PATH" \
    -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$ROOT_DIR"/Repose/*.swift -o "$APP_PATH/Contents/MacOS/Repose"

# Generate the app icon from the repository's original PNG.
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ROOT_DIR/assets/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/LICENSE" "$APP_PATH/Contents/Resources/LICENSE"

python3 - "$ROOT_DIR/Repose/Info.plist" "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
info.update({
    "CFBundleName": "Repose Ring",
    "CFBundleDisplayName": "Repose Ring",
    "CFBundleIdentifier": "com.repose.localring",
    "CFBundleVersion": "9",
    "CFBundleShortVersionString": "1.1.1-ring.7",
    "CFBundleExecutable": "Repose",
    "LSMinimumSystemVersion": "13.0",
    "CFBundleIconFile": "AppIcon",
    "SUEnableAutomaticChecks": False,
})
info.pop("SUFeedURL", None)
info.pop("SUPublicEDKey", None)
with open(sys.argv[2], "wb") as destination:
    plistlib.dump(info, destination)
PY

# Finder/iCloud may attach metadata to generated .app folders in Documents.
# Remove only signing-incompatible metadata from this build artifact.
xattr -dr com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_PATH" "$BUILD_DIR/Repose-Ring.zip"
echo "Built: $APP_PATH"
