# Outlook Calendar MCP

A read-only MCP server for calendar data synced into macOS Calendar.app. It is designed for VS Code MCP clients and IBM Bob.

## Setup

1. Sign in to the IBM account in macOS Calendar.app.
2. Confirm the calendar appears in Calendar.app.
3. Open this workspace in VS Code.
4. Start or reload the `outlook-calendar` MCP server when VS Code offers it.

The workspace configuration is in `.vscode/mcp.json`:

```json
{
  "servers": {
    "outlook-calendar": {
      "type": "stdio",
      "command": "go",
      "args": ["run", "./cmd/server"],
      "cwd": "${workspaceFolder}",
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

## Local Probe

For a direct JSON check outside MCP:

```bash
go run ./cmd/calendar-local-probe -days 1 -limit 10
```

## Backend status

The default backend is macOS Calendar.app via AppleScript. Microsoft Graph is retained as an optional future backend, but IBM's tenant requires preauthorization for standalone Graph clients. Outlook ICS publishing was unavailable for this tenant.

## Development

```bash
go test ./...
go run ./cmd/server
```
