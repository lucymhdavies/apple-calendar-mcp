# Outlook Calendar MCP

A read-only MCP server for calendar data synced into macOS Calendar.app. It is designed for VS Code MCP clients and IBM Bob.

## Setup

1. Sign in to the IBM account in macOS Calendar.app.
2. Confirm the calendar appears in Calendar.app.
3. Open this workspace in VS Code.
4. Build the Swift server with `./scripts/build-release.sh`.
5. Start or reload the `outlook-calendar` MCP server when VS Code offers it.

To run the REST API as a menu bar app instead, launch the packaged executable
with `REST_ENABLED=true`. It starts on `127.0.0.1:8765` by default:

```bash
REST_ENABLED=true .build/release/CalendarMCP.app/Contents/MacOS/CalendarMCP
```

The menu bar item starts the API automatically and provides controls to stop it,
restart it, copy its URL, or quit. Set `REST_HOST`, `REST_PORT`, and
`CALENDAR_NAME` to customize the listener. Non-loopback hosts also require
`REST_TOKEN` with at least 16 characters; send it as a bearer token.

The workspace configuration is in `.vscode/mcp.json`:

```json
{
  "servers": {
    "outlook-calendar": {
      "type": "stdio",
      "command": "${workspaceFolder}/.build/release/CalendarMCP.app/Contents/MacOS/CalendarMCP",
      "args": [],
      "env": { "CALENDAR_NAME": "Calendar" }
    }
  }
}
```

Bob can use the same workspace MCP server. No Microsoft Graph token or Azure app registration is required for the macOS backend.

## Tools

- `list_calendars`: list calendars visible to Calendar.app.
- `list_events`: list events overlapping an RFC3339 `from`/`to` range. Defaults to the next 24 hours.
- `get_event`: retrieve one event by its Calendar.app event ID, including the description and attendees.
- `get_freebusy`: derive busy slots from the local calendar. It does not query other people's availability.

Descriptions can contain meeting links, dial-in details, and passcodes. Treat MCP results as private calendar data.

## REST API

The read-only API uses these endpoints:

- `GET /health`
- `GET /v1/calendars`
- `GET /v1/events?from=<RFC3339>&to=<RFC3339>&limit=<integer>`
- `GET /v1/events?id=<Calendar.app event ID>`
- `GET /v1/freebusy?from=<RFC3339>&to=<RFC3339>&email=<address>`

Date ranges default to the next 24 hours. Free/busy is derived from the local
calendar and does not query other people's availability. The REST server is
disabled by default and binds to loopback unless explicitly configured.

Use `list_events` through the MCP panel for the same direct calendar check.

## Development

```bash
./scripts/build-release.sh
```
