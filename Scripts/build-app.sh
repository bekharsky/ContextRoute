#!/bin/sh
set -eu

SCRIPT_DIR=$(dirname "$0")
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
APP_BUNDLE="$PROJECT_DIR/ContextRoute.app"
DERIVED_DATA="$PROJECT_DIR/.build-xcode"

xcodebuild \
    -quiet \
    -project "$PROJECT_DIR/ContextRoute.xcodeproj" \
    -scheme ContextRoute \
    -configuration Release \
    -sdk macosx \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    build

rm -rf "$APP_BUNDLE"
ditto "$DERIVED_DATA/Build/Products/Release/ContextRoute.app" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
printf 'Built %s\n' "$APP_BUNDLE"
