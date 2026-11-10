#!/usr/bin/env bash
#
# Package, sign, and notarize Dot for public release.
# Mirrors the production distribution pipeline used by Kitlington's Hex & Scroll.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
RELEASE_DIR="$BUILD_DIR/release"
APP="$BUILD_DIR/Dot.app"
DMG_NAME="Dot.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
VOLUME_NAME="Dot"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }

cd -- "$PROJECT_DIR"

log "Building release bundle via scripts/build.sh..."
"$PROJECT_DIR/scripts/build.sh"

mkdir -p "$RELEASE_DIR"
rm -f "$DMG_PATH"

if [ -n "$DEVELOPER_ID" ]; then
    log "Signing Dot.app with Developer ID: $DEVELOPER_ID (Hardened Runtime)..."
    codesign --force --deep --options runtime --timestamp \
        --sign "Developer ID Application: $DEVELOPER_ID" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    warn "DEVELOPER_ID not set. Signing ad-hoc with hardened runtime for local distribution..."
    codesign --force --deep --options runtime --sign - "$APP"
fi

log "Creating DMG package: $DMG_PATH..."
STAGING_DIR="$(mktemp -d -t dot-dmg-staging-XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

if [ -n "$DEVELOPER_ID" ]; then
    log "Signing DMG container..."
    codesign --force --sign "Developer ID Application: $DEVELOPER_ID" --timestamp "$DMG_PATH"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    log "Submitting $DMG_NAME to Apple Notary Service (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    log "Stapling notarization ticket to $DMG_NAME..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    warn "NOTARY_PROFILE not set. Skipping Apple notarization."
    warn "To notarize: NOTARY_PROFILE=<profile-name> ./scripts/release.sh"
fi

log "Calculating SHA-256 checksum..."
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "$SHA256  $DMG_NAME" > "$RELEASE_DIR/$DMG_NAME.sha256"

log "Release packaging complete!"
printf "  App:      %s\n" "$APP"
printf "  DMG:      %s\n" "$DMG_PATH"
printf "  SHA-256:  %s\n" "$SHA256"
