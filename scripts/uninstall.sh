#!/usr/bin/env bash
#
# Remove Dot: unload the LaunchAgent, delete the plist and the app.
#
# The configuration and the log are left alone: they are the user's data.
#
set -euo pipefail

APP_NAME="Dot"
INSTALLED_APP="/Applications/$APP_NAME.app"
LABEL="com.local.dot"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_VALUE="$(id -u)"

log() { printf '%s\n' "$*"; }

log "unloading the LaunchAgent"
launchctl bootout "gui/$UID_VALUE/$LABEL" 2>/dev/null || true

if [ -f "$AGENT" ]; then
  log "removing $AGENT"
  rm -f -- "$AGENT"
fi

if [ -d "$INSTALLED_APP" ]; then
  log "removing $INSTALLED_APP"
  rm -rf -- "$INSTALLED_APP"
fi

log ""
log "Dot is removed."
log "The log and the configuration are still in:"
log "  $HOME/Library/Logs/$APP_NAME"
log "  $HOME/Library/Application Support/$APP_NAME"
log "Delete them by hand if you want them gone."
