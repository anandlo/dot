#!/usr/bin/env bash
#
# Install Dot: build the app, copy it into /Applications and install the
# LaunchAgent that starts it at login.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Dot"
INSTALLED_APP="/Applications/$APP_NAME.app"
LABEL="com.local.dot"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/$APP_NAME"
UID_VALUE="$(id -u)"

log() { printf '%s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

"$PROJECT_DIR/scripts/build.sh"

# MimoTalk, Rune and Ion were this product's earlier names. Remove their
# agents and their apps on upgrade, so two menu bar items can never appear at
# the same time and no stale agent keeps launching an old binary.
for STALE_LABEL in com.mimotalk.app com.local.rune com.local.ion; do
  launchctl bootout "gui/$UID_VALUE/$STALE_LABEL" 2>/dev/null || true
  rm -f -- "$HOME/Library/LaunchAgents/$STALE_LABEL.plist"
done
for STALE_APP in MimoTalk Rune Ion; do
  rm -rf -- "/Applications/$STALE_APP.app"
done

# The environment variables are named after the product. The old spelling is
# still accepted so an existing shell snippet keeps working.
DOT_CAPTURE_DIR="${DOT_CAPTURE_DIR:-${ION_CAPTURE_DIR:-}}"
DOT_TEST_TRIGGER="${DOT_TEST_TRIGGER:-${ION_TEST_TRIGGER:-}}"
DOT_ALLOW_TEST_TRIGGER="${DOT_ALLOW_TEST_TRIGGER:-${ION_ALLOW_TEST_TRIGGER:-0}}"

log "installing $INSTALLED_APP"
rm -rf -- "$INSTALLED_APP"
cp -R -- "$PROJECT_DIR/build/$APP_NAME.app" "$INSTALLED_APP"

log "installing the LaunchAgent"
mkdir -p -- "$HOME/Library/LaunchAgents" "$LOG_DIR"
EXTRA_ENVIRONMENT=""
EXTRA_ARGUMENTS=""
if [ -n "${DOT_CAPTURE_DIR:-}" ]; then
  EXTRA_ENVIRONMENT="$EXTRA_ENVIRONMENT		<key>DOT_CAPTURE_DIR</key>
		<string>$DOT_CAPTURE_DIR</string>
"
fi
# The test trigger can start a recording without the user asking. It is only
# installed when the person running the install asks for it explicitly.
if [ -n "${DOT_TEST_TRIGGER:-}" ] && [ "${DOT_ALLOW_TEST_TRIGGER:-0}" = "1" ]; then
  EXTRA_ENVIRONMENT="$EXTRA_ENVIRONMENT		<key>DOT_TEST_TRIGGER</key>
		<string>$DOT_TEST_TRIGGER</string>
"
  EXTRA_ARGUMENTS="		<string>--allow-test-trigger</string>
"
fi
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$HOME</string>
$EXTRA_ENVIRONMENT	</dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>ProgramArguments</key>
	<array>
		<string>$INSTALLED_APP/Contents/MacOS/Dot</string>
$EXTRA_ARGUMENTS	</array>
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
launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
# launchd needs a moment to let the old job go before a new one can take its
# place; without the wait the bootstrap fails with an I/O error.
for _ in $(seq 1 20); do
  if ! launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
if ! launchctl bootstrap "gui/$UID_VALUE" "$AGENT"; then
  sleep 2
  launchctl bootstrap "gui/$UID_VALUE" "$AGENT"
fi
launchctl enable "gui/$UID_VALUE/$LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$UID_VALUE/$LABEL"

sleep 1
log "the agent is running:"
launchctl print "gui/$UID_VALUE/$LABEL" | sed -n '1,12p'

log ""
log "Dot is installed."
