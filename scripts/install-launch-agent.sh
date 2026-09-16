#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/.build/release/CalendarMCP.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/CalendarMCP"
LABEL="com.lucymhdavies.CalendarMCP"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/CalendarMCP"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
TEMPLATE="$ROOT_DIR/scripts/$LABEL.plist"

if [ ! -x "$EXECUTABLE" ]; then
    printf 'Release app not found. Build it first with ./scripts/build-release.sh\n' >&2
    exit 1
fi

mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
sed -e "s|__EXECUTABLE__|$EXECUTABLE|g" -e "s|__LOG_DIR__|$LOG_DIR|g" "$TEMPLATE" > "$PLIST_PATH"
plutil -lint "$PLIST_PATH"
launchctl bootstrap "gui/$UID" "$PLIST_PATH"
launchctl kickstart -k "gui/$UID/$LABEL"
printf 'Installed and started %s\n' "$LABEL"
printf 'Logs: %s\n' "$LOG_DIR"
