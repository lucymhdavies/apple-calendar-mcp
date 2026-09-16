# Repository Guide

## Project

This is a macOS Swift 6 executable that reads EventKit calendars and exposes the same read-only calendar service through:

- MCP stdio mode for VS Code and IBM Bob.
- An optional REST server owned by a menu bar application.

The REST mode is enabled with `REST_ENABLED=true` or `--rest`.

## Important Files

- `Sources/CalendarMCP/CalendarBackend.swift`: EventKit access and calendar mapping.
- `Sources/CalendarMCP/CalendarService.swift`: shared calendar operations and validation.
- `Sources/CalendarMCP/RESTServer.swift`: Network.framework HTTP server, API-key storage, and menu bar lifecycle.
- `Sources/CalendarMCP/CalendarMCPApp.swift`: MCP registration and startup mode selection.
- `Sources/CalendarMCP/Info.plist`: app bundle metadata and EventKit permission text.
- `scripts/build-release.sh`: release app packaging and ad-hoc signing.
- `scripts/install-launch-agent.sh`: install and start the per-user login service.

## Development

Use the full Xcode toolchain, not Command Line Tools alone:

```bash
swift test
swift build -c release
./scripts/build-release.sh
```

The live MCP smoke test uses newline-delimited JSON-RPC over the packaged executable. The REST smoke test uses `curl` against `/health` and `/v1/calendars`.

## REST Behavior

REST binds to `127.0.0.1:8765` by default. LAN exposure is opt-in from the menu bar item. Enabling LAN exposure persists the preference in `UserDefaults` and stores a generated bearer token in the macOS Keychain. Do not log or commit API keys.

The LaunchAgent is user-scoped and should be tested with:

```bash
./scripts/install-launch-agent.sh
./scripts/uninstall-launch-agent.sh
```

## Release Checklist

1. Update the app and MCP server version consistently in `Info.plist` and `CalendarMCPApp.swift`.
2. Add a dated entry to `CHANGELOG.md`.
3. Run `swift test`, `swift build -c release`, and `./scripts/build-release.sh`.
4. Verify MCP initialization and REST `/health` locally.
5. Commit, tag with the SemVer version such as `v0.1.1`, push, and create the GitHub release.

Keep `.vscode/settings.json` user-specific changes out of product commits unless explicitly requested.
