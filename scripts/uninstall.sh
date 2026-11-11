#!/usr/bin/env bash
#
# Remove Dot: unload the LaunchAgent, delete the plist and the app.
#
# The configuration and the log are left alone: they are the user's data.
#
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The LaunchAgent label and the legacy labels come from the one file every
# script shares.
. "$PROJECT_DIR/scripts/config.sh"
APP_NAME="Dot"
INSTALLED_APP="/Applications/$APP_NAME.app"
LABEL="$AGENT_LABEL"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_VALUE="$(id -u)"

log() { printf '%s\n' "$*"; }

log "unloading the LaunchAgent"
for STALE_LABEL in $LABEL $LEGACY_AGENT_LABELS; do
  launchctl bootout "gui/$UID_VALUE/$STALE_LABEL" 2>/dev/null || true
  STALE_AGENT="$HOME/Library/LaunchAgents/$STALE_LABEL.plist"
  if [ -f "$STALE_AGENT" ]; then
    log "removing $STALE_AGENT"
    rm -f -- "$STALE_AGENT"
  fi
done

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
