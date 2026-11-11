#!/usr/bin/env bash
#
# Build Dot and assemble Dot.app.
#
# The bundle is signed with the self-signed identity from config.sh when it is
# installed, and ad-hoc when it is not. Dot needs the microphone and the
# Accessibility permission, and macOS records both against the code signature:
# an ad-hoc signature is identified by the build's own hash, so every rebuild
# would ask for them again. scripts/signing-identity.sh creates the identity.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/Dot.app"
# The version and the identity come from the two files every script shares.
# shellcheck source=scripts/config.sh
. "$PROJECT_DIR/scripts/config.sh"
# shellcheck source=scripts/signing.sh
. "$PROJECT_DIR/scripts/signing.sh"

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

[ -n "$MARKETING_VERSION" ] || {
  printf 'error: VERSION is empty\n' >&2
  exit 1
}

cd -- "$PROJECT_DIR"

log "building the release binary"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

log "assembling $APP"
rm -rf -- "$APP"
mkdir -p -- "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -- "$BIN_PATH/Dot" "$APP/Contents/MacOS/Dot"
cp -- "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -- "$PROJECT_DIR/Resources/AppIcon-1024.png" "$APP/Contents/Resources/AppIcon-1024.png"
cp -- "$PROJECT_DIR/Resources/MenuGlyph.png" "$APP/Contents/Resources/MenuGlyph.png"
cp -- "$PROJECT_DIR/Resources/MenuGlyph@2x.png" "$APP/Contents/Resources/MenuGlyph@2x.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Dot</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Dot</string>
	<key>CFBundleDisplayName</key>
	<string>Dot</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$MARKETING_VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Dot records your microphone so it can turn your speech into text.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Dot controls Notes, Mail, Messages, Music, Spotify, System Events and your browser only when you ask it to, for example to add a note, send a message or change the track that is playing.</string>
	<key>NSRemindersFullAccessUsageDescription</key>
	<string>Dot adds reminders you ask for by voice.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Dot reads your calendars when you ask what is next and adds events you ask for.</string>
	<key>NSContactsUsageDescription</key>
	<string>Dot looks up a person's details when you ask it to write to them.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

dot_resolve_signing
case "$DOT_SIGN_KIND" in
  developer-id) log "signing with $DOT_SIGN_IDENTITY (hardened runtime, secure timestamp)" ;;
  self-signed) log "signing with $DOT_SIGN_IDENTITY (hardened runtime)" ;;
  adhoc)
    warn "no code-signing identity named \"$SIGN_IDENTITY\" was found: signing ad-hoc."
    warn "an ad-hoc signature is identified by this build's own hash, so macOS asks"
    warn "for the microphone and Accessibility again after every rebuild."
    warn "run ./scripts/signing-identity.sh once to make an identity that lasts."
    ;;
esac
dot_sign_bundle "$DOT_SIGN_IDENTITY" "$APP" "$DOT_SIGN_TIMESTAMP" "$DOT_SIGN_ENTITLEMENTS"
log "verifying the signature, nested code first, then the bundle"
dot_verify_bundle "$APP"

log "built $APP"
log "designated requirement: $(dot_designated_requirement "$APP")"
