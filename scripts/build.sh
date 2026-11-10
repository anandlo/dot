#!/usr/bin/env bash
#
# Build Dot and assemble Dot.app.
#
# The bundle is signed ad-hoc: Dot needs the microphone and the
# Accessibility permission, and both of those are tied to the signature. An
# ad-hoc signature is enough for a locally built app.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/Dot.app"
BUNDLE_ID="${BUNDLE_ID:-com.anandlo.dot}"

log() { printf '%s\n' "$*"; }

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
	<string>0.1.0-beta</string>
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
	<string>Dot posts the paste keystroke so it can deliver a transcript to the app you are working in.</string>
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

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
log "signing the bundle ($SIGNING_IDENTITY)"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

log "built $APP"
