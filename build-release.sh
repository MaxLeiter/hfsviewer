#!/bin/bash
set -e

# Simple release builder for HFSViewer
# Usage: ./build-release.sh

echo "Building HFSViewer Release..."

# Config
PROJECT="com.maxleiter.HFSViewer/com.maxleiter.HFSViewer.xcodeproj"
SCHEME="com.maxleiter.HFSViewer"
VERSION=$(date +"%Y.%m.%d")
BUILD_DIR="build"
RELEASE_DIR="releases"

# Clean and build
echo "→ Cleaning..."
xcodebuild clean -project "$PROJECT" -scheme "$SCHEME" -configuration Release > /dev/null 2>&1

echo "→ Building Release configuration..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

# Find the built app
APP_PATH=$(find "$BUILD_DIR" -name "*.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
  echo "✗ Build failed - no .app found"
  exit 1
fi

echo "→ Found app at: $APP_PATH"

# Create releases directory
mkdir -p "$RELEASE_DIR"

# Zip it up
ZIP_NAME="HFSViewer-$VERSION.zip"
echo "→ Creating $ZIP_NAME..."

# Get absolute paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_PATH="$SCRIPT_DIR/$RELEASE_DIR/$ZIP_NAME"

# Create zip from the directory containing the app
cd "$(dirname "$APP_PATH")"
zip -r -q "$RELEASE_PATH" "$(basename "$APP_PATH")"
cd - > /dev/null

echo "✓ Release built successfully!"
echo "  Location: $RELEASE_DIR/$ZIP_NAME"
echo "  Size: $(du -h "$RELEASE_DIR/$ZIP_NAME" | cut -f1)"
