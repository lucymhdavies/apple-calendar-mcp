#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/.build/release/CalendarMCP.app"

swift build -c release --package-path "$ROOT_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/CalendarMCP" "$APP_DIR/Contents/MacOS/CalendarMCP"
cp "$ROOT_DIR/Sources/CalendarMCP/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"

printf 'Built %s\n' "$APP_DIR"