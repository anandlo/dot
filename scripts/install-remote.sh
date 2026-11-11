#!/bin/sh
#
# Install Dot from a GitHub release, over curl.
#
#   curl -fsSL https://raw.githubusercontent.com/anandlo/dot/main/scripts/install-remote.sh | sh
#
# To install a version other than the newest one, pin it:
#
#   curl -fsSL https://raw.githubusercontent.com/anandlo/dot/main/scripts/install-remote.sh \
#     | DOT_VERSION=<version> sh
#
# The script downloads the release zip, checks it against the release's
# SHA256SUMS, puts Dot.app in /Applications, and loads the same LaunchAgent the
# local installer writes, so the app is running when the script returns.
#
# Why this lane has no Gatekeeper prompt: the quarantine attribute
# (com.apple.quarantine) is applied by the applications that download a file —
# Safari, Chrome, Mail, AirDrop — and by Homebrew, which calls quarantine(1)
# itself on every cask. curl and wget do not apply it. A file that never had the
# attribute is not put through Gatekeeper's first-launch path, so a build
# installed this way opens with no "unidentified developer" dialog and no
# "Dot is damaged" dialog. The script only reports that the attribute is absent;
# it never removes one, because removing quarantine from an app that arrived some
# other way is the user's decision and not this script's.
#
# This script replaces an existing /Applications/Dot.app only when it can read
# that bundle's identifier and find it to be Dot's. It never touches the apps
# this product used to be called (MimoTalk, Rune, Ion) — that cleanup belongs to
# scripts/install.sh, which is run by someone who has the repository open and can
# see what it is doing.
set -eu
# pipefail is not POSIX; macOS's sh supports it, so use it when it is there.
# shellcheck disable=SC3040
(set -o pipefail) 2>/dev/null && set -o pipefail || true

REPO="anandlo/dot"
BUNDLE_ID="com.anandlo.dot"
APP_NAME="Dot"
INSTALLED_APP="/Applications/$APP_NAME.app"
LABEL="$BUNDLE_ID"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/$APP_NAME"
UID_VALUE="$(id -u)"

log() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  # Prints the header comment, from line 2 to the first line that is not one, so
  # the usage text cannot drift from this file. Only reachable when the script
  # was saved and run as a file: a piped script has no readable $0.
  if [ -f "$0" ]; then
    sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  else
    printf 'Install Dot from a GitHub release: see the header of this script.\n'
  fi
  exit 0
fi

# MARK: - What this machine is

MACHINE="$(uname -m)"
case "$MACHINE" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x64" ;;
  *) die "unsupported machine architecture: $MACHINE" ;;
esac

[ "$(uname -s)" = "Darwin" ] || die "Dot is a macOS app; this is not a Mac"

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] 2>/dev/null \
  || die "Dot needs macOS 14 (Sonoma) or later; this is $(sw_vers -productVersion)"

command -v curl >/dev/null 2>&1 || die "curl is required and was not found"

# MARK: - Which release

api_get() {
  # -s without -S: a missing /releases/latest is expected while every release is
  # a prerelease, and curl's 404 line for it would read like a failure.
  curl -fsL --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: dot-install' \
    "$1"
}

TAG=""
if [ -n "${DOT_VERSION:-}" ]; then
  case "$DOT_VERSION" in
    v*) TAG="$DOT_VERSION" ;;
    *) TAG="v$DOT_VERSION" ;;
  esac
  log "using the version you pinned: $TAG"
else
  JSON="$(api_get "https://api.github.com/repos/$REPO/releases/latest" || true)"
  TAG="$(printf '%s\n' "$JSON" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)"
  if [ -z "$TAG" ]; then
    # /releases/latest deliberately leaves out prereleases. While Dot is in
    # beta every release is one, so the list endpoint — newest first, prereleases
    # included — is the fallback that can actually answer.
    JSON="$(api_get "https://api.github.com/repos/$REPO/releases?per_page=1" || true)"
    TAG="$(printf '%s\n' "$JSON" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -1)"
  fi
fi

[ -n "$TAG" ] \
  || die "could not read the latest release from github.com/$REPO (no release yet, or the API is rate-limited). Pin one with DOT_VERSION=<version>"

VERSION="${TAG#v}"
ZIP_NAME="$APP_NAME-$VERSION-$ARCH.zip"
BASE_URL="https://github.com/$REPO/releases/download/$TAG"
log "installing Dot $VERSION for $ARCH from $TAG"

# MARK: - Download and check

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dot-install-XXXXXX")"
STAGED="$INSTALLED_APP.incoming.$$"
REPLACED="$WORK/Dot.app.replaced"
SWAP_STARTED=0
RESTORE_FAILED=0
cleanup() {
  # If the swap died between moving the old bundle aside and moving the new one
  # in, put the old one back. It lives inside $WORK, so this has to run before
  # the directory goes.
  if [ "$SWAP_STARTED" = 1 ] && [ -e "$REPLACED" ] && [ ! -e "$INSTALLED_APP" ]; then
    if mv "$REPLACED" "$INSTALLED_APP"; then
      warn "the install did not finish; your previous $INSTALLED_APP was put back"
    else
      RESTORE_FAILED=1
      warn "could not put the previous bundle back: it is at $REPLACED"
    fi
  fi
  if [ "$RESTORE_FAILED" = 0 ]; then
    rm -r "$WORK" 2>/dev/null || true
  fi
  rm -r "$STAGED" 2>/dev/null || true
}
trap cleanup EXIT

log "downloading $ZIP_NAME"
curl -fL --proto '=https' --tlsv1.2 --progress-bar \
  -o "$WORK/$ZIP_NAME" "$BASE_URL/$ZIP_NAME" \
  || {
    if [ "$ARCH" = "x64" ]; then
      die "release $TAG has no $ZIP_NAME. The release artifacts are built for Apple silicon only; on an Intel Mac, build from source: https://github.com/$REPO#install"
    fi
    die "release $TAG has no $ZIP_NAME. Check the release page for what it actually attached."
  }

log "downloading SHA256SUMS"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/SHA256SUMS" "$BASE_URL/SHA256SUMS" \
  || die "release $TAG has no SHA256SUMS, so the download cannot be verified. Not installing it."

EXPECTED="$(awk -v name="$ZIP_NAME" '$2 == name { print $1 }' "$WORK/SHA256SUMS")"
[ -n "$EXPECTED" ] || die "SHA256SUMS in release $TAG has no entry for $ZIP_NAME"
ACTUAL="$(shasum -a 256 "$WORK/$ZIP_NAME" | awk '{ print $1 }')"
[ "$EXPECTED" = "$ACTUAL" ] \
  || die "checksum mismatch for $ZIP_NAME: expected $EXPECTED, got $ACTUAL. Not installing it."
log "checksum matches: $ACTUAL"

# MARK: - Unpack and check again

EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"
# ditto is used instead of unzip because it restores the bundle's permissions,
# symlinks and extended attributes; an unarchiver that drops those can leave the
# code signature invalid even though every file is present.
ditto -x -k "$WORK/$ZIP_NAME" "$EXTRACT"
[ -d "$EXTRACT/$APP_NAME.app" ] || die "$ZIP_NAME does not contain $APP_NAME.app"

EXTRACTED="$EXTRACT/$APP_NAME.app"
EXTRACTED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$EXTRACTED/Contents/Info.plist" 2>/dev/null || true)"
[ "$EXTRACTED_ID" = "$BUNDLE_ID" ] \
  || die "$ZIP_NAME contains an app with identifier '$EXTRACTED_ID', not Dot's"

EXTRACTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$EXTRACTED/Contents/Info.plist" 2>/dev/null || true)"
[ "$EXTRACTED_VERSION" = "$VERSION" ] \
  || die "$ZIP_NAME contains version '$EXTRACTED_VERSION', not $VERSION"

codesign --verify --strict --verbose=2 "$EXTRACTED" \
  || die "the app in $ZIP_NAME does not satisfy its own signature. Not installing it."
log "the unpacked app is Dot $EXTRACTED_VERSION and its signature verifies"

# MARK: - Install

[ -w "/Applications" ] \
  || die "/Applications is not writable by $(whoami). Run this as an administrator, or drag Dot.app there yourself."

if [ -e "$INSTALLED_APP" ]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
  [ "$EXISTING_ID" = "$BUNDLE_ID" ] \
    || die "$INSTALLED_APP exists and is not Dot (identifier '${EXISTING_ID:-unreadable}'). Move it aside yourself; this script will not delete something it cannot identify."
  log "replacing $INSTALLED_APP (Dot $EXISTING_ID already installed)"
fi

# The new bundle is staged inside /Applications and checked there before it is
# swapped in. The outgoing bundle is moved aside first and deleted only after the
# swap succeeds, so a failure leaves the old app in place instead of leaving
# nothing.
rm -r "$STAGED" 2>/dev/null || true
ditto "$EXTRACTED" "$STAGED"

STAGED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$STAGED/Contents/Info.plist" 2>/dev/null || true)"
[ "$STAGED_ID" = "$BUNDLE_ID" ] || die "the staged copy is not Dot; leaving your installation alone"
codesign --verify --strict "$STAGED" || die "the staged copy does not verify; leaving your installation alone"

log "stopping the running copy"
launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
# launchd needs a moment to let the old job go before a new one can take its
# place; without the wait the bootstrap fails with an I/O error.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done

if [ -e "$INSTALLED_APP" ]; then
  SWAP_STARTED=1
  mv "$INSTALLED_APP" "$REPLACED"
fi
mv "$STAGED" "$INSTALLED_APP"
SWAP_STARTED=0
if [ -e "$REPLACED" ]; then
  rm -r "$REPLACED"
fi
log "installed $INSTALLED_APP"

# MARK: - Start at login, then start

log "writing the LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$HOME</string>
	</dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED_APP/Contents/MacOS/Dot</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$LOG_DIR/launchd.err.log</string>
	<key>StandardOutPath</key>
	<string>$LOG_DIR/launchd.out.log</string>
</dict>
</plist>
PLIST
plutil -lint "$AGENT" >/dev/null

log "loading the LaunchAgent"
if ! launchctl bootstrap "gui/$UID_VALUE" "$AGENT"; then
  sleep 2
  launchctl bootstrap "gui/$UID_VALUE" "$AGENT"
fi
launchctl enable "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

# MARK: - Say what happened

sleep 1
QUARANTINED=0
for CHECKED in "$INSTALLED_APP" "$INSTALLED_APP/Contents/MacOS/Dot"; do
  if [ -n "$(xattr -p com.apple.quarantine "$CHECKED" 2>/dev/null || true)" ]; then
    QUARANTINED=1
  fi
done
if [ "$QUARANTINED" = 1 ]; then
  warn "$INSTALLED_APP carries com.apple.quarantine after a curl download, which should not happen"
  warn "If macOS refuses to open it: System Settings → Privacy & Security → Open Anyway"
else
  log "no com.apple.quarantine on $INSTALLED_APP: Gatekeeper has nothing to object to"
fi

log ""
log "Dot $EXTRACTED_VERSION is installed and running."
log ""
log "macOS will ask for the two permissions Dot uses, the first time it needs them:"
log "  Microphone     — only while the shortcut is held"
log "  Accessibility  — only to paste the transcript at your cursor"
log "Input Monitoring is not needed and is never requested."
log ""
log "Hold ⌃⌥R to dictate. The dot in the menu bar opens Settings."
log ""
log "To remove it:"
log "  launchctl bootout gui/$UID_VALUE/$LABEL"
log "  rm -r \"$AGENT\" \"$INSTALLED_APP\""
log "  rm -r \"$HOME/Library/Application Support/Dot\" \"$LOG_DIR\"   # config and logs"
