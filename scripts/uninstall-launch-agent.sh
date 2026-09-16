#!/bin/sh
set -eu

LABEL="com.lucymhdavies.CalendarMCP"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST_PATH"
printf 'Uninstalled %s\n' "$LABEL"
