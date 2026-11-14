#!/bin/bash
# Build, sign, notarize and package "gRPC Server Manager" (arm64) with gRPCServerProxy inside.
#
#   ./build.sh                        dev build: Developer ID signed, no notarization
#   RELEASE=1 ./build.sh              release: hardened runtime, notarized, stapled, DMG, SHA-256
#   SKIP_PROXY_BUILD=1 ./build.sh     reuse the proxy of the last build (Apps/gRPCServerProxy/build)
#
# Environment:
#   CODESIGN_IDENTITY     name of the Developer ID Application certificate (required);
#                         security find-identity -v -p codesigning
#   NOTARY_PROFILE        notarytool keychain profile (xcrun notarytool store-credentials <profile>), or
#   APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID
#   VERSION_LABEL         name part of the DMG, default: CFBundleShortVersionString (for example 0.1.0-rc1)
#
# The app is signed from the inside out (proxy first, then the app) and notarized once; the ticket
# is stapled to the app, not to the DMG. Run it as your own user, not with sudo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

APP_NAME="gRPCServerManager"
APP_DISPLAY_NAME="gRPC Server Manager"
PROXY_NAME="gRPCServerProxy"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_DISPLAY_NAME.app"
RELEASE="${RELEASE:-0}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=(main.swift AppDelegate.swift ManagedProcess.swift QueueMonitor.swift)
FRAMEWORKS=(-framework Cocoa -framework ServiceManagement)
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
VERSION_LABEL="${VERSION_LABEL:-$VERSION}"

echo -e "${GREEN}=== $APP_DISPLAY_NAME $VERSION_LABEL ===${NC}"

if [ "$(id -u)" = "0" ]; then
    echo -e "${RED}Do not run this script with sudo: the Developer ID of the user is not visible then.${NC}" >&2
    exit 1
fi

SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    echo -e "${RED}CODESIGN_IDENTITY is not set (name of your 'Developer ID Application' certificate).${NC}" >&2
    echo "  security find-identity -v -p codesigning" >&2
    exit 1
fi
if [ -n "$SIGN_ID" ] && ! security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
    echo -e "${RED}No signing identity '$SIGN_ID' in the keychain.${NC}" >&2
    exit 1
fi

NOTARY_ARGS=()
if [ "$RELEASE" = "1" ]; then
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
    else
        echo -e "${RED}RELEASE=1 needs NOTARY_PROFILE or APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID.${NC}" >&2
        exit 1
    fi
fi

# ── Proxy ──────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Building ${PROXY_NAME}…${NC}"
PROXY_ENV=(RELEASE="$RELEASE")
[ "${SKIP_PROXY_BUILD:-0}" = "1" ] && PROXY_ENV+=(SKIP_BUILD=1)
env "${PROXY_ENV[@]}" "$SCRIPT_DIR/../gRPCServerProxy/build.sh"
PROXY_BIN="$SCRIPT_DIR/../gRPCServerProxy/build/$PROXY_NAME"

# ── Manager ────────────────────────────────────────────────────────────────────
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

echo -e "${YELLOW}Compiling $APP_NAME (arm64)…${NC}"
swiftc -O -whole-module-optimization -sdk "$SDK" "${FRAMEWORKS[@]}" -target arm64-apple-macos13.0 \
    "${SOURCES[@]}" -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP_BUNDLE/Contents/"
if [ -d "AppIcon.iconset" ]; then
    iconutil -c icns -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" AppIcon.iconset
elif [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
fi
cp "$PROXY_BIN" "$APP_BUNDLE/Contents/MacOS/$PROXY_NAME"

# ── Sign (inside out) ──────────────────────────────────────────────────────────
# Always with the Developer ID: macOS keeps a permission (Files & Folders for the Draw Things
# projects) by the signature, and an ad-hoc signature is a new, unknown program with every build.
if [ -n "$SIGN_ID" ]; then
    if [ "$RELEASE" = "1" ]; then
        echo -e "${YELLOW}Signing with Developer ID (hardened runtime)…${NC}"
        codesign --force --options runtime --timestamp --sign "$SIGN_ID" \
            --identifier com.satin-island.grpc-server-proxy "$APP_BUNDLE/Contents/MacOS/$PROXY_NAME"
        codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP_BUNDLE"
    else
        echo -e "${YELLOW}Signing with Developer ID (dev build)…${NC}"
        codesign --force --timestamp=none --sign "$SIGN_ID" \
            --identifier com.satin-island.grpc-server-proxy "$APP_BUNDLE/Contents/MacOS/$PROXY_NAME"
        codesign --force --timestamp=none --sign "$SIGN_ID" "$APP_BUNDLE"
    fi
else
    echo -e "${RED}No signing identity.${NC}" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
for bin in "$APP_BUNDLE/Contents/MacOS/"*; do
    archs="$(lipo -archs "$bin")"
    [ "$archs" = "arm64" ] || { echo -e "${RED}$bin is not arm64-only: $archs${NC}" >&2; exit 1; }
done

if [ "$RELEASE" != "1" ]; then
    echo -e "${GREEN}=== Dev build complete ===${NC}"
    echo "  App: $APP_BUNDLE"
    exit 0
fi

# ── Notarize and staple the app ────────────────────────────────────────────────
echo -e "${YELLOW}Submitting to Apple Notary Service (may take a few minutes)…${NC}"
NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
SUBMISSION="$(xcrun notarytool submit "$NOTARIZE_ZIP" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
echo "$SUBMISSION"
rm -f "$NOTARIZE_ZIP"
if ! echo "$SUBMISSION" | grep -q "status: Accepted"; then
    SUBMISSION_ID="$(echo "$SUBMISSION" | sed -n 's/^ *id: *//p' | head -1)"
    echo -e "${RED}ERROR: notarization was not accepted.${NC}" >&2
    [ -n "$SUBMISSION_ID" ] && echo "  Details: xcrun notarytool log $SUBMISSION_ID <credentials>" >&2
    exit 1
fi

# The ticket may not be available right away ("Record not found"): try again with growing pauses.
echo -e "${YELLOW}Stapling the notarization ticket…${NC}"
delay=10
for attempt in 1 2 3 4 5 6 7 8; do
    if xcrun stapler staple "$APP_BUNDLE"; then break; fi
    [ "$attempt" = "8" ] && { echo -e "${RED}Stapling failed.${NC}" >&2; exit 1; }
    echo "  attempt $attempt failed, next in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2 > 120 ? 120 : delay * 2))
done
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
echo -e "${GREEN}✓ Gatekeeper accepts the app.${NC}"

# ── DMG and checksum ───────────────────────────────────────────────────────────
echo -e "${YELLOW}Creating DMG…${NC}"
FINAL_DMG="$BUILD_DIR/gRPC-Server-Manager-$VERSION_LABEL-arm64.dmg"
STAGING="$BUILD_DIR/dmg_staging"
rm -f "$FINAL_DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGING" -ov -format UDZO "$FINAL_DMG"
rm -rf "$STAGING"
(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$FINAL_DMG")" > "$(basename "$FINAL_DMG").sha256")

echo -e "${GREEN}=== Release build complete ===${NC}"
echo "  App:    $APP_BUNDLE"
echo "  DMG:    $FINAL_DMG"
echo "  SHA256: $(cut -d' ' -f1 "$FINAL_DMG.sha256")"
