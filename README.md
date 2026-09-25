# CalendarAPI

A read-only calendar API for data synced into macOS Calendar.app. It supports MCP clients such as VS Code and IBM Bob, as well as direct REST consumers.

## Setup

1. Sign in to the IBM account in macOS Calendar.app.
2. Confirm the calendar appears in Calendar.app.
3. Open this workspace in VS Code.
4. Build the Swift server with `./scripts/build-release.sh`.
5. Start or reload the `calendar-api` MCP server when VS Code offers it.

To run the REST API as a menu bar app instead, launch the packaged executable
with `REST_ENABLED=true`. It starts on `127.0.0.1:8765` by default:

```bash
REST_ENABLED=true .build/release/CalendarMCP.app/Contents/MacOS/CalendarMCP
```

The menu bar item starts the API automatically and provides controls to stop it,
restart it, expose it to the LAN, configure the port, choose the calendar, copy
its URL, or quit. The selected port and calendar are persisted in
`UserDefaults`. `REST_HOST`, `REST_PORT`, and `CALENDAR_NAME` provide startup
defaults for environments without menu-bar interaction.

By default, the API binds only to `127.0.0.1` and does not require
authentication. Use **Expose API to LAN** in the menu to bind to all local
interfaces. The app generates a random API key, stores it in 1Password, and
shows it for copying. 1Password CLI and desktop-app integration must be
configured before enabling LAN access. The LAN preference is stored in
`UserDefaults`, so both the LAN setting and API key persist across app restarts
and login startup. LAN mode also publishes a Bonjour `_http._tcp` service named
`CalendarAPI`, allowing clients to discover the current port without relying on
the configured port number.

LAN requests must send the key as a bearer token:

```bash
curl -H 'Authorization: Bearer YOUR_API_KEY' \
  http://YOUR-MAC-IP:8765/v1/calendars
```

To discover the advertised service from another Mac:

```bash
dns-sd -B _http._tcp local
dns-sd -L CalendarAPI _http._tcp local
```

The discovered service resolves to the API's current host and port. Clients
still need the bearer token for all endpoints except `/health`.

`/health` remains available without authentication. To configure LAN access
before the menu bar app starts, set `REST_HOST=0.0.0.0` and provide a
`REST_TOKEN` with at least 16 characters in the LaunchAgent environment.

To start the REST menu bar app automatically when you log in, build the release
app and install its per-user LaunchAgent:

```bash
./scripts/build-release.sh
./scripts/install-launch-agent.sh
```

The login service uses the persisted menu bar preference for its binding and
keeps the app running if it exits. A fresh installation starts loopback-only;
if LAN exposure was previously enabled, it resumes LAN mode with the stored key.
Remove it with:

```bash
./scripts/uninstall-launch-agent.sh
```

The LaunchAgent writes logs to `~/Library/Logs/CalendarMCP`. LAN configuration
such as `REST_HOST`, `REST_PORT`, and `REST_TOKEN` should be added to the
generated `~/Library/LaunchAgents/com.lucymhdavies.CalendarMCP.plist` before
starting the service.

The workspace configuration is in `.vscode/mcp.json`:

```json
{
  "servers": {
    "calendar-api": {
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

The complete wire-level reference, including JSON schemas, query parameters,
authentication, and errors, is in [docs/api.md](docs/api.md).

Services with a browser frontend should perform Bonjour discovery in their
backend and proxy CalendarAPI requests. Browser JavaScript cannot browse mDNS
services directly; keeping discovery and the bearer token in the backend also
avoids requiring CORS on this local API.

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

## Code signing and Calendar access

`./scripts/build-release.sh` ad-hoc signs the app by default (`CODESIGN_IDENTITY`
unset). Ad-hoc signing gets a new identity on every build, so macOS treats each
rebuild as a different app and any previously granted Calendar access is
orphaned — the app has to be re-approved after every rebuild, and other launch
modes (e.g. a stdio MCP client like Bob invoking the binary directly, without a
window server connection to show the permission prompt) can never get their own
grant and depend on the REST fallback instead.

To get a stable identity so Calendar access survives rebuilds and direct
(non-REST) EventKit access works for stdio clients too:

1. Open **Keychain Access** (Spotlight → "Keychain Access").
2. Menu bar → **Keychain Access → Certificate Assistant → Create a Certificate...**
3. **Name:** `CalendarMCP Local Signing` (or any name you'll remember).
4. **Identity Type:** Self-Signed Root
5. **Certificate Type:** Code Signing
6. Click **Create**, then continue/done through the rest.
7. In Keychain Access, find the new certificate (under "My Certificates" in the
   `login` keychain), double-click it, expand **Trust**, and set **"When using
   this certificate"** to **Always Trust**.
8. Build with the identity set:

   ```bash
   CODESIGN_IDENTITY="CalendarMCP Local Signing" ./scripts/build-release.sh
   ```

9. Launch the app once in a way that can show the system permission prompt
   (e.g. via the menu bar/REST mode or the LaunchAgent) and approve Calendar
   access. As long as you keep signing with the same identity, that grant
   persists across future rebuilds, and any stdio invocation of the same
   binary (Bob, VS Code, etc.) will see access already granted with no REST
   fallback needed.

## Development

```bash
./scripts/build-release.sh
```
