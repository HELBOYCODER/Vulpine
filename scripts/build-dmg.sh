#!/usr/bin/env bash
set -euo pipefail

# Vulpine macOS arm64 DMG Builder
# Builds a signed .app bundle and creates a drag-and-drop .dmg installer.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARCH="arm64"
echo "==> [1/6] Building Vulpine for macOS (${ARCH})..."
swift build -c release --arch "$ARCH"

echo "==> [2/6] Locating compiled binary..."
BINARY_PATH=""
CANDIDATE_PATHS=(
    ".build/${ARCH}-apple-macosx/release/Vulpine"
    ".build/release/Vulpine"
)
for candidate in "${CANDIDATE_PATHS[@]}"; do
    if [ -f "$candidate" ]; then
        BINARY_PATH="$candidate"
        break
    fi
done

if [ -z "$BINARY_PATH" ]; then
    BINARY_PATH=$(find .build -name Vulpine -type f -perm -111 | grep -v '\.dSYM' | head -n 1)
fi

if [ -z "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Could not find compiled Vulpine binary."
    exit 1
fi

echo "Found binary at: $BINARY_PATH"

echo "==> [3/6] Assembling Vulpine.app bundle..."
APP_DIR="build/Vulpine.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/Vulpine"
chmod +x "$MACOS_DIR/Vulpine"
cp "Vulpine/Info.plist" "$CONTENTS_DIR/Info.plist"

# Generate native macOS AppIcon.icns from appiconset
if command -v iconutil >/dev/null 2>&1; then
    echo "Converting AppIcon.appiconset to AppIcon.icns..."
    TMP_ICONSET=$(mktemp -d)/AppIcon.iconset
    cp -R "Vulpine/Resources/Assets.xcassets/AppIcon.appiconset" "$TMP_ICONSET"
    iconutil -c icns "$TMP_ICONSET" -o "$RESOURCES_DIR/AppIcon.icns" || true
    rm -rf "$(dirname "$TMP_ICONSET")"
fi

# Copy any remaining asset catalogs
if [ -d "Vulpine/Resources/Assets.xcassets" ]; then
    cp -R "Vulpine/Resources/Assets.xcassets" "$RESOURCES_DIR/" 2>/dev/null || true
fi

echo "==> [4/6] Code-signing Vulpine.app (ad-hoc for Apple Silicon)..."
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - --entitlements "Vulpine/Vulpine.entitlements" "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR" || true
    echo "Code-signing completed."
fi

echo "==> [5/6] Creating DMG package..."
DMG_NAME="Vulpine-arm64.dmg"
DMG_OUT="build/${DMG_NAME}"
DMG_STAGING="build/dmg_staging"

rm -rf "$DMG_STAGING" "$DMG_OUT"
mkdir -p "$DMG_STAGING"

cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "Vulpine" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUT"

rm -rf "$DMG_STAGING"

echo "==> [6/6] Generating SHA-256 checksum..."
cd build
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$DMG_NAME" > "${DMG_NAME}.sha256"
fi

echo "=========================================="
echo "SUCCESS: $DMG_OUT created successfully!"
ls -lh "$DMG_NAME"*
echo "=========================================="
