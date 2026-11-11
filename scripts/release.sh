#!/usr/bin/env bash
#
# Package Dot for public release: sign it, verify it, build the DMG and the
# zip, checksum both, and render the Homebrew cask for the artifact just built.
#
# Signing follows the order scripts/signing.sh defines: a Developer ID when
# DEVELOPER_ID is set, Dot's self-signed identity when it is installed, and
# ad-hoc when neither is available. Dot has no Apple Developer ID and is not
# notarized, so in the last two cases Gatekeeper cannot chain the signature to
# Apple and `spctl` rejects the result. That is expected, and the script reports
# it as the outcome it is rather than as a failure of the build. Set DEVELOPER_ID
# and, with a paying Apple account, NOTARY_PROFILE to produce a build that
# passes; neither is required, and neither branch is reached unless you set it.
#
# The self-signed identity matters even though Gatekeeper still objects: it keeps
# the designated requirement identical across releases, so the permissions a
# person granted survive the next update. An ad-hoc build is identified by its
# own hash and loses them.
#
# Output, all in build/release:
#   Dot-<version>-<arch>.dmg     the disk image a person downloads
#   Dot-<version>-<arch>.zip     the same app, archived; what the curl path uses
#   SHA256SUMS                   both of the above, for `shasum -a 256 -c`
#   homebrew/Casks/dot.rb         the cask rendered for this build
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The version and the identity come from the two files every script shares.
# shellcheck source=scripts/config.sh
. "$PROJECT_DIR/scripts/config.sh"
# shellcheck source=scripts/signing.sh
. "$PROJECT_DIR/scripts/signing.sh"

BUILD_DIR="$PROJECT_DIR/build"
RELEASE_DIR="$BUILD_DIR/release"
APP="$BUILD_DIR/Dot.app"
VERSION="$MARKETING_VERSION"
VOLUME_NAME="Dot"
CASK="$PROJECT_DIR/dist/homebrew/Casks/dot.rb"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd -- "$PROJECT_DIR"

# The version ends up in a file name, a tag and a URL, so anything that would
# change the meaning of one of those is refused here rather than at upload time.
case "$VERSION" in
  *[!0-9A-Za-z.-]*) fail "VERSION contains a character that cannot appear in an artifact name: $VERSION" ;;
esac

log "Building release bundle via scripts/build.sh..."
"$PROJECT_DIR/scripts/build.sh"

# The artifact is named for the architecture it actually contains, read from the
# binary rather than assumed: build.sh runs `swift build -c release`, which
# builds for the host and nothing else.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Dot")"
case "$ARCHS" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x64" ;;
  *" "*)
    case "$ARCHS" in
      *arm64*x86_64*|*x86_64*arm64*) ARCH="universal" ;;
      *) fail "unexpected architectures in the binary: $ARCHS" ;;
    esac
    ;;
  *) fail "unexpected architecture in the binary: $ARCHS" ;;
esac

DMG_NAME="Dot-$VERSION-$ARCH.dmg"
ZIP_NAME="Dot-$VERSION-$ARCH.zip"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"
SUMS_PATH="$RELEASE_DIR/SHA256SUMS"

log "Dot $VERSION, $ARCH, from $APP"

rm -rf -- "$RELEASE_DIR"
mkdir -p -- "$RELEASE_DIR"

# MARK: - Signing

dot_resolve_signing
case "$DOT_SIGN_KIND" in
  developer-id)
    log "Signing with $DOT_SIGN_IDENTITY (hardened runtime, secure timestamp)"
    ;;
  self-signed)
    log "Signing with $DOT_SIGN_IDENTITY (hardened runtime)"
    log "Not a Developer ID: Gatekeeper still refuses the first launch, but the"
    log "designated requirement stays the same across releases, so permissions do."
    ;;
  adhoc)
    warn "DEVELOPER_ID is not set and no identity named \"$SIGN_IDENTITY\" is installed."
    warn "Signing ad-hoc: the designated requirement is this build's hash, so every"
    warn "person who installs it grants microphone and Accessibility again on the"
    warn "next update. Run scripts/signing-identity.sh to create a lasting identity."
    ;;
esac

dot_sign_bundle "$DOT_SIGN_IDENTITY" "$APP" "$DOT_SIGN_TIMESTAMP" "$DOT_SIGN_ENTITLEMENTS"

log "Verifying the signature, nested code first, then the bundle"
dot_verify_bundle "$APP"
log "Designated requirement: $(dot_designated_requirement "$APP")"

# MARK: - DMG

log "Creating DMG: $DMG_NAME"
STAGING_DIR="$(mktemp -d -t dot-dmg-staging-XXXXXX)"
MOUNT_DIR="$(mktemp -d -t dot-dmg-mount-XXXXXX)"
cleanup() {
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  rm -rf -- "$STAGING_DIR" "$MOUNT_DIR"
}
trap cleanup EXIT

cp -R -- "$APP" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
cp -- "$PROJECT_DIR/LICENSE" "$STAGING_DIR/LICENSE" 2>/dev/null || true

hdiutil create -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null

if [ -n "$DEVELOPER_ID" ]; then
  log "Signing the DMG container"
  codesign --force --sign "$DOT_SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

# The DMG is only worth publishing if it mounts and contains the version that
# was just built, so both are checked. A mount failure is reported rather than
# fatal: a build host without a session can refuse to attach an image, and that
# says nothing about the artifact.
log "Checking the DMG mounts and carries Dot $VERSION"
if hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null 2>&1; then
  [ -d "$MOUNT_DIR/Dot.app" ] || fail "the DMG has no Dot.app in it"
  DMG_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$MOUNT_DIR/Dot.app/Contents/Info.plist")"
  [ "$DMG_VERSION" = "$VERSION" ] \
    || fail "the DMG carries version $DMG_VERSION, not $VERSION"
  [ -L "$MOUNT_DIR/Applications" ] || warn "the DMG has no /Applications symlink"
  log "the DMG holds Dot.app $DMG_VERSION and the /Applications symlink"
  hdiutil detach "$MOUNT_DIR" -quiet >/dev/null
else
  warn "could not attach the DMG on this host to check its contents"
fi

# MARK: - Zip

# The zip is what a `curl` install downloads. `ditto` is used on both sides
# because it keeps the archive's resource forks, permissions and symlinks intact;
# an app unarchived by a tool that drops those loses its signature. Both are
# verified below against a fresh extraction rather than trusted.
log "Creating zip: $ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"

log "Checking the zip round-trips the signature"
EXTRACT_DIR="$(mktemp -d -t dot-zip-check-XXXXXX)"
ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"
dot_verify_bundle "$EXTRACT_DIR/Dot.app"
cmp -s "$APP/Contents/MacOS/Dot" "$EXTRACT_DIR/Dot.app/Contents/MacOS/Dot" \
  || fail "the executable in the zip differs from the built one"
rm -rf -- "$EXTRACT_DIR"
log "the extracted app verifies and its executable is byte-identical"

# MARK: - Checksums

log "Writing SHA256SUMS"
(
  cd -- "$RELEASE_DIR"
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)

# MARK: - Gatekeeper, stated plainly

log "Asking Gatekeeper what it makes of the result"
SPCTL_APP="$(spctl -a -vvv --assess --type execute "$APP" 2>&1 || true)"
SPCTL_DMG="$(spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" 2>&1 || true)"
printf '%s\n' "$SPCTL_APP"
printf '%s\n' "$SPCTL_DMG"

if [ -n "$DEVELOPER_ID" ]; then
  case "$SPCTL_APP" in
    *accepted*) : ;;
    *) fail "Gatekeeper rejected a Developer ID build; not publishing it" ;;
  esac
else
  case "$SPCTL_APP" in
    *accepted*)
      warn "Gatekeeper accepted a build without a Developer ID, which it should not be able to do"
      ;;
    *)
      # This is the documented, expected outcome: no Developer ID, no
      # notarization, so the artifact is rejected until the person allows it in
      # System Settings. Not an error, and not something to hide. A self-signed
      # build is rejected here too; the difference is that its permissions
      # survive the next update.
      log "Gatekeeper rejected the $DOT_SIGN_LABEL build, as expected: no Developer ID, no notarization."
      log "The documented first-launch path is System Settings → Privacy & Security → Open Anyway."
      ;;
  esac
fi

# MARK: - Notarization, only if asked for

if [ -n "$NOTARY_PROFILE" ]; then
  [ -n "$DEVELOPER_ID" ] \
    || fail "NOTARY_PROFILE is set but DEVELOPER_ID is not: there is nothing to notarize"
  log "Submitting $DMG_NAME to the Apple Notary Service (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  log "Stapling the notarization ticket"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  # The zip cannot be stapled; a stapled DMG is what ships. Refreshing the
  # checksum keeps SHA256SUMS true after the ticket lands.
  (
    cd -- "$RELEASE_DIR"
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
  )
else
  log "NOTARY_PROFILE is not set: skipping notarization."
  log "With a paid Apple account: DEVELOPER_ID=<name> NOTARY_PROFILE=<profile> $0"
fi

# MARK: - The cask

# The cask's `url` names the arm64 DMG, so only a build that produced one can
# render it. It is written to build/release and not over the tracked copy in
# dist/: a checksum is only true for the exact bytes that were built, and the
# bytes CI builds are not the bytes this machine builds. The tracked copy stays
# a template with a placeholder checksum, so nobody can copy it into a tap and
# publish a stanza that points at the wrong number.
if [ "$ARCH" = "arm64" ]; then
  DMG_SHA256="$(awk '$2 == "Dot-'"$VERSION"'-arm64.dmg" { print $1 }' "$SUMS_PATH")"
  [ -n "$DMG_SHA256" ] || fail "no checksum for the arm64 DMG to put in the cask"
  [ -f "$CASK" ] || fail "the cask template is missing: $CASK"

  RENDERED_CASK="$RELEASE_DIR/homebrew/Casks/dot.rb"
  mkdir -p "$(dirname "$RENDERED_CASK")"

  # Exactly two lines are volatile: the version and the checksum. Everything
  # else in the cask is hand-written and has to survive this untouched.
  awk -v version="$VERSION" -v sha256="$DMG_SHA256" '
    /^  version "/ && !done_version { print "  version \"" version "\""; done_version = 1; next }
    /^  sha256 "/ && !done_sha { print "  sha256 \"" sha256 "\""; done_sha = 1; next }
    { print }
    END {
      if (!done_version) { exit 1 }
      if (!done_sha) { exit 2 }
    }
  ' "$CASK" > "$RENDERED_CASK" || fail "could not render the cask: $CASK is missing a version or sha256 line"

  if command -v ruby >/dev/null 2>&1; then
    ruby -c "$RENDERED_CASK" >/dev/null 2>&1 \
      || fail "the rendered cask is not valid Ruby: $RENDERED_CASK"
  else
    warn "ruby is not installed, so the rendered cask was not syntax-checked"
  fi

  TEMPLATE_VERSION="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$CASK")"
  if [ "$TEMPLATE_VERSION" != "$VERSION" ]; then
    warn "the tracked cask still says $TEMPLATE_VERSION, not $VERSION: bump it in the same commit"
  fi

  log "Rendered the cask for this build: ${RENDERED_CASK#"$PROJECT_DIR/"}"
  log "Copy that file, not the template, into the tap (see dist/homebrew/README.md)"
else
  warn "not rendering the cask: its url names the arm64 DMG and this build is $ARCH"
fi

# MARK: - Summary

log "Release artifacts in ${RELEASE_DIR#"$PROJECT_DIR/"}"
(
  cd -- "$RELEASE_DIR"
  for artifact in "$DMG_NAME" "$ZIP_NAME" SHA256SUMS; do
    printf '  %-40s %8s\n' "$artifact" "$(du -h "$artifact" | awk '{print $1}')"
  done
)
printf '\n'
cat -- "$SUMS_PATH"

printf '\n'
printf '  App:     %s\n' "$APP"
printf '  Version: %s (%s)\n' "$VERSION" "$ARCH"
printf '  Signed:  %s\n' "$DOT_SIGN_LABEL"
printf '  spctl:   %s\n' "$(printf '%s' "$SPCTL_APP" | head -1)"
