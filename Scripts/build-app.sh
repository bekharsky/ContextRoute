#!/bin/sh
set -eu

SCRIPT_DIR=$(dirname "$0")
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
APP_BUNDLE="$PROJECT_DIR/ContextRoute.app"
DERIVED_DATA="$PROJECT_DIR/.build-xcode"

SIGNING_IDENTITY="${CONTEXTROUTE_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Developer ID Application:/ { print $2; exit }')
fi

case "$SIGNING_IDENTITY" in
    "Developer ID Application:"*) ;;
    *)
        echo "A valid Developer ID Application identity is required." >&2
        echo "Install the certificate in your login keychain or set CONTEXTROUTE_SIGNING_IDENTITY." >&2
        exit 1
        ;;
esac

xcodebuild \
    -quiet \
    -project "$PROJECT_DIR/ContextRoute.xcodeproj" \
    -scheme ContextRoute \
    -configuration Release \
    -sdk macosx \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    ENABLE_APP_SANDBOX=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ContextRoute.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Xcode did not produce $BUILT_APP" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
ditto "$BUILT_APP" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

signature_details=$(codesign --display --verbose=4 "$APP_BUNDLE" 2>&1)
if ! printf '%s\n' "$signature_details" | grep -q 'Authority=Developer ID Application:'; then
    echo "The built app is not signed with a Developer ID Application identity." >&2
    exit 1
fi
if ! printf '%s\n' "$signature_details" | grep -q 'flags=.*runtime'; then
    echo "The built app is missing the Hardened Runtime signature flag." >&2
    exit 1
fi

printf 'Built and verified %s\n' "$APP_BUNDLE"
printf '%s\n' "$signature_details" | grep -E 'Authority=Developer ID Application:|flags=|Timestamp=' | head -3
