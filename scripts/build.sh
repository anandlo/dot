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

# The Icon Composer document compiles to Assets.car, which is what macOS 26 and
# later read. AppIcon.icns above stays the file macOS 14 and 15 read: those have
# no icon stack of their own and draw the icon exactly as supplied.
#
# actool also writes an icns of its own with four slots. That one is deliberately
# not used: the committed icns is drawn from the vector at all ten, so the small
# and the large sizes agree.
if [ -f "$PROJECT_DIR/Resources/AppIcon.icon/icon.json" ] && xcrun --find actool >/dev/null 2>&1; then
  ICON_BUILD="$BUILD_DIR/icon-assets"
  rm -r -- "$ICON_BUILD" 2>/dev/null || true
  mkdir -p -- "$ICON_BUILD"
  if xcrun actool "$PROJECT_DIR/Resources/AppIcon.icon" \
    --compile "$ICON_BUILD" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_BUILD/partial.plist" >/dev/null 2>&1
  then
    cp -- "$ICON_BUILD/Assets.car" "$APP/Contents/Resources/Assets.car"
    log "compiled AppIcon.icon into Assets.car ($(( $(stat -f%z "$APP/Contents/Resources/Assets.car") / 1024 )) KB)"
  else
    warn "actool could not compile AppIcon.icon: the bundle ships the classic icns only"
  fi
else
  warn "actool not found: the bundle ships the classic icns only"
fi

# CFBundleIconName is only written when the stack it names is in the bundle.
ICON_NAME_ENTRY=""
if [ -f "$APP/Contents/Resources/Assets.car" ]; then
  ICON_NAME_ENTRY=$'\t<key>CFBundleIconName</key>\n\t<string>AppIcon</string>'
fi

# The app's typeface is embedded but never committed: the foundry's licence
# allows it in the application and forbids redistributing the file. A checkout
# without it still builds and falls back to the system face.
FONT_ENTRY=""
mkdir -p -- "$APP/Contents/Resources/Fonts"
FONT_COUNT=0
for font in "$PROJECT_DIR"/Resources/Fonts/*.ttf; do
  [ -f "$font" ] || continue
  cp -- "$font" "$APP/Contents/Resources/Fonts/"
  FONT_COUNT=$((FONT_COUNT + 1))
done
if [ "$FONT_COUNT" -gt 0 ]; then
  FONT_ENTRY=$'\t<key>ATSApplicationFontsPath</key>\n\t<string>Fonts</string>'
  log "embedded $FONT_COUNT font file(s)"
else
  rmdir -- "$APP/Contents/Resources/Fonts" 2>/dev/null || true
  warn "Resources/Fonts holds no font: the app will fall back to the system face."
  warn "run ./scripts/fetch-fonts.sh to fetch the typeface the app is designed in."
fi

# The bundle identifier and version also populate Info.plist.
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
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
$ICON_NAME_ENTRY
$FONT_ENTRY
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$MARKETING_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Dot records your microphone so it can turn your speech into text.</string>
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
