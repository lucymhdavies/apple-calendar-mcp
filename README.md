# Outlook Calendar MCP

A read-only MCP server for calendar data synced into macOS Calendar.app. It is designed for VS Code MCP clients and IBM Bob.

## Setup

1. Sign in to the IBM account in macOS Calendar.app.
2. Confirm the calendar appears in Calendar.app.
3. Open this workspace in VS Code.
4. Build the Swift server with `./scripts/build-release.sh`.
5. Start or reload the `outlook-calendar` MCP server when VS Code offers it.

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

Use `list_events` through the MCP panel for the same direct calendar check.

## Development

```bash
./scripts/build-release.sh
```
