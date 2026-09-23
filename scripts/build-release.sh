#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/.build/release/CalendarMCP.app"
ENTITLEMENTS="$ROOT_DIR/Sources/CalendarMCP/CalendarMCP.entitlements"
# Ad-hoc ("-") signing gets a new identity on every build, which orphans any
# previously granted TCC permissions (Calendar access has to be re-approved
# after every rebuild). Set CODESIGN_IDENTITY to a stable local or Developer ID
# certificate name (e.g. "CalendarMCP Local Signing") so grants persist across
# rebuilds.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
BUILD_REVISION=$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)
BUILD_TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
BUILD_REVISION="$BUILD_REVISION+$BUILD_TIMESTAMP"
if test -n "$(git -C "$ROOT_DIR" status --porcelain)"; then
	BUILD_REVISION="$BUILD_REVISION-dirty"
fi

swift build -c release --package-path "$ROOT_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/CalendarMCP" "$APP_DIR/Contents/MacOS/CalendarMCP"
cp "$ROOT_DIR/Sources/CalendarMCP/Info.plist" "$APP_DIR/Contents/Info.plist"
plutil -replace CalendarMCPBuildRevision -string "$BUILD_REVISION" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign "$CODESIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"

printf 'Built %s revision=%s (signed with %s)\n' "$APP_DIR" "$BUILD_REVISION" "$CODESIGN_IDENTITY"