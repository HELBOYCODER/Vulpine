#!/usr/bin/env bash
set -euo pipefail

# Vulpine macOS Build & Run Script
# Builds the executable via Swift Package Manager and launches it.

cd "$(dirname "$0")/.."

echo "==> Building Vulpine for macOS..."
swift build -c release

APP_DIR="build/Vulpine.app/Contents"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"

cp .build/release/Vulpine "$APP_DIR/MacOS/"
cp Vulpine/Info.plist "$APP_DIR/"
cp -r Vulpine/Resources/Assets.xcassets "$APP_DIR/Resources/" 2>/dev/null || true

echo "==> Vulpine.app built successfully at build/Vulpine.app"
echo "==> To run: open build/Vulpine.app"
