# Plan: Rewrite MCP Server in Swift using EventKit

## Background

The current server is written in Go and queries macOS Calendar.app via AppleScript
(`osascript`). This has two fundamental problems:

1. **Recurring events are broken.** AppleScript's `whose` filter compares against the
   *master* event's `start date` / `end date`, not individual occurrence dates. A weekly
   recurring meeting created six months ago has `start date` six months in the past, so
   it is filtered out before Go ever sees it. There is no AppleScript API for querying
   occurrences by date.

2. **Slow.** Each `osascript` call takes ~30 seconds to run against the Exchange calendar.

The fix is to replace the osascript backend with **EventKit** (`EKEventStore`), which
provides `events(matching:)` — a purpose-built API that expands recurring occurrences
into individual instances keyed by their actual occurrence date. It is fast and correct.

Rather than keeping the Go wrapper and adding a Swift subprocess, the entire server can
be rewritten in Swift using the official
[`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk)
(v0.11+, MIT licensed, actively maintained, 1400+ stars). This eliminates the Go
dependency entirely and gives direct access to EventKit without any IPC.

---

## Target Architecture

```
Bob MCP client
      │  stdio (JSON-RPC)
      ▼
CalendarMCP  (Swift binary, built with `swift build -c release`)
      │
      └── EventKit (EKEventStore)  ←  macOS Calendar.app / Exchange sync
```

The Swift binary:
- Is a Swift Package (SPM) at the repo root
- Depends only on `modelcontextprotocol/swift-sdk` (no other third-party deps)
- Uses `StdioTransport` — same transport the Go server uses today
- Reads `CALENDAR_NAME` from the environment (same as today)
- Exposes the same 4 tools with the same JSON schemas and output shapes

---

## File Layout

```
Package.swift                   ← new; replaces go.mod as the build entry point
Sources/
  CalendarMCP/
    main.swift                  ← entry point: EKEventStore auth + MCP server setup
    CalendarBackend.swift       ← EventKit queries (list calendars, list events, get event)
    Models.swift                ← Codable structs matching the existing JSON output shapes
    Logging.swift               ← stderr logger (mirrors what the Go server does today)
```

The existing Go source (`cmd/`, `internal/`, `go.mod`, `go.sum`) is left in place
unchanged. It can be removed in a follow-up once the Swift server is verified.

---

## Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "CalendarMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/CalendarMCP"
        ),
    ]
)
```

---

## Tool Schemas (must match existing output exactly)

All four tools already exist in the Go server. The Swift server must produce identical
JSON output so that any consumers (Bob, tests, etc.) see no change in behaviour.

### `list_calendars`
- **Input:** none
- **Output:** `{ "calendars": [ { "id", "name", "color", "can_edit" } ] }`
- **EventKit:** `EKEventStore().calendars(for: .event)`

### `list_events`
- **Input:** `from` (RFC3339, optional), `to` (RFC3339, optional), `limit` (int, optional)
- **Output:** `{ "events": [ <Event> ] }`
- **EventKit:** `EKEventStore().events(matching: store.predicateForEvents(withStart:end:calendars:))`
- Defaults: `from = now`, `to = from + 24h`

### `get_event`
- **Input:** `id` (string, required) — the `EKEvent.eventIdentifier`
- **Output:** `{ "event": <Event> }`
- **EventKit:** `EKEventStore().event(withIdentifier:)`
- Note: for recurring events, `eventIdentifier` on an occurrence differs from the
  master. Store `.calendarItemIdentifier` or both. See notes below.

### `get_freebusy`
- **Input:** `from`, `to`, `emails` ([]string, optional)
- **Output:** `{ "results": [ { "email", "availability", "busy_slots", "source", "note" } ] }`
- **Implementation:** calls `list_events` internally, maps to time slots. Identical
  logic to the Go implementation.

### Event JSON shape
```json
{
  "id": "...",
  "calendar_id": "...",
  "subject": "...",
  "body": "...",
  "start": "2026-09-16T08:30:00+01:00",
  "end": "2026-09-16T09:30:00+01:00",
  "is_all_day": false,
  "location": "...",
  "web_link": "...",
  "recurrence": "...",
  "status": "none",
  "attendees": [
    { "email": "...", "name": "...", "status": "accepted" }
  ]
}
```

---

## EventKit Permission Handling

EventKit requires the user to grant calendar access. On first run macOS shows a system
dialog; subsequent runs are immediate.

The Swift binary must:
1. Call `EKEventStore().requestFullAccessToEvents { granted, error in ... }` (macOS 14+)
   or `requestAccess(to: .event)` (macOS 13 fallback).
2. If denied, print a clear error to stderr and exit with code 1.
3. **The permission request is async.** The MCP server must not start handling requests
   until access is granted. Use `await withCheckedContinuation` or Swift concurrency
   to block startup on the grant.

> **macOS permission note:** The binary needs a `Info.plist` with
> `NSCalendarsUsageDescription` *only* if distributed as an app bundle. For a
> command-line tool run from the terminal (which this is), macOS grants access based on
> the Terminal/process having calendar permission — no plist needed. If the binary is
> code-signed for distribution, a plist entitlement is required.

---

## EKEvent → JSON Field Mapping

| JSON field | EKEvent property | Notes |
|---|---|---|
| `id` | `eventIdentifier` | occurrence-specific for recurring events |
| `calendar_id` | `calendar.calendarIdentifier` | or use `calendar.title` to match `CALENDAR_NAME` |
| `subject` | `title` | |
| `body` | `notes` | may be nil → `""` |
| `start` | `startDate` | format as RFC3339 with timezone offset |
| `end` | `endDate` | format as RFC3339 with timezone offset |
| `is_all_day` | `isAllDay` | |
| `location` | `location` | may be nil → `""` |
| `web_link` | `url?.absoluteString` | may be nil → `""` |
| `recurrence` | `recurrenceRules?.first` → RRULE string | `EKRecurrenceRule` has no built-in RRULE serialiser; reconstruct manually or use `calendarItem.recurrenceRules` and format as `FREQ=...;INTERVAL=...` etc. If too complex, emit `""` for now and add a TODO |
| `status` | `status.rawValue` | EKEventStatus: `.none`→`"none"`, `.confirmed`→`"confirmed"`, `.tentative`→`"tentative"`, `.cancelled`→`"cancelled"` |
| `attendees[].email` | `ekParticipant.url.absoluteString` with `mailto:` prefix stripped | |
| `attendees[].name` | `ekParticipant.name ?? ""` | |
| `attendees[].status` | `ekParticipant.participantStatus` | `.accepted`→`"accepted"`, `.declined`→`"declined"`, `.tentative`→`"tentative"`, `.unknown`→`"unknown"`, `.pending`→`"unknown"` |

---

## Swift 6 Concurrency Notes

`swift-sdk` requires Swift 6 strict concurrency. `EKEventStore` is not `Sendable`.
Wrap all EventKit calls in a single actor:

```swift
actor CalendarBackend {
    private let store = EKEventStore()
    // all methods are actor-isolated — safe to call from async contexts
}
```

The `main.swift` entry point must be a top-level `async` function or use
`@main` + `static func main() async throws`. The simplest pattern for a CLI:

```swift
import MCP
import Foundation

// Top-level async entry point (Swift 5.5+, works with Swift 6)
let backend = CalendarBackend()
try await backend.requestAccess()

let server = Server(
    name: "outlook-calendar",
    version: "0.1.0",
    capabilities: .init(tools: .init())
)
// register handlers …
let transport = StdioTransport()
try await server.start(transport: transport)
// block until stdin closes / server stops
try await Task.sleep(for: .seconds(365 * 24 * 3600))
```

Note: Swift 6 requires a `@main` struct or explicit `RunLoop.main.run()` / task sleep
to keep the process alive. The `Task.sleep` trick works; alternatively use
`swift-service-lifecycle` as shown in the `swift-sdk` README.

---

## Known EventKit Quirk: Event Identifiers for Recurring Events

`EKEvent.eventIdentifier` for a recurring occurrence includes an occurrence-specific
suffix. `EKEventStore.event(withIdentifier:)` accepts this and returns the correct
occurrence. However, the identifier is not stable across re-syncs for Exchange
calendars.

For `get_event`, use `eventIdentifier` as the ID (same as the Go server used the
AppleScript `id` property). Document this limitation in a comment.

---

## Logging

Mirror the Go server's stderr logging:
- Prefix: `[outlook-calendar]`
- Log tool start with parameters, completion with elapsed time, errors with message.
- Log EventKit permission grant/denial at startup.

Use `fputs` to stderr (no dependency on `os.Logger` / `OSLog` needed for a CLI tool,
though either works).

---

## Build & Install

```bash
# Development build
swift build

# Release build (what .bob/mcp.json should point at)
swift build -c release

# The binary lands at:
.build/release/CalendarMCP
```

Update `.bob/mcp.json` `command` to `.build/release/CalendarMCP` (absolute path) after
first release build.

---

## `.bob/mcp.json` Update

After building, update `command` and reduce `timeout` — EventKit is fast so 30 seconds
is ample (vs the 300s needed for osascript):

```json
{
  "mcpServers": {
    "outlook-calendar": {
      "command": "/Users/strawb/git_src/github.com/lucymhdavies/apple-calendar-mcp/.build/release/CalendarMCP",
      "args": [],
      "env": {
        "CALENDAR_NAME": "Calendar"
      },
      "timeout": 30000,
      "alwaysAllow": ["get_event", "get_freebusy", "list_calendars", "list_events"]
    }
  }
}
```

---

## Implementation Steps (in order)

1. **Write `Package.swift`** — SPM manifest with `swift-sdk` dependency, macOS 13 platform.

2. **Write `Sources/CalendarMCP/Models.swift`** — `Codable` structs for `CalendarInfo`,
   `Event`, `Attendee`, `FreeBusyResult`, `TimeSlot` matching the JSON shapes above.

3. **Write `Sources/CalendarMCP/CalendarBackend.swift`** — EventKit wrapper:
   - `requestAccess()` async → throws if denied
   - `listCalendars(name:)` → `[CalendarInfo]`
   - `listEvents(calendarName:from:to:)` → `[Event]`
   - `getEvent(calendarName:id:)` → `Event`

4. **Write `Sources/CalendarMCP/Logging.swift`** — simple stderr logger.

5. **Write `Sources/CalendarMCP/main.swift`** — MCP server entry point:
   - Read `CALENDAR_NAME` from env (default `"Calendar"` if unset, matching Go behaviour)
   - Request EventKit access (await; exit 1 on denial)
   - Construct `Server` with name `"outlook-calendar"`, title `"Outlook Calendar"`,
     version `"0.1.0"`, description `"Read-only access to calendars synced into macOS Calendar."`
   - Register `ListTools` and `CallTool` handlers
   - Start with `StdioTransport`

6. **Run `swift build`** — fix any compile errors.

7. **Run `swift build -c release`** — produce the release binary.

8. **Update `.bob/mcp.json`** — point `command` at `.build/release/CalendarMCP`.

9. **Reconnect in Bob MCP panel** and test all four tools.

10. **Verify recurring events are returned** for `list_events` tomorrow.

---

## Additional Implementation Details

### `CALENDAR_NAME` scoping
`list_events`, `get_event`, and `get_freebusy` must filter to only the named calendar.
In EventKit, look up the `EKCalendar` where `calendar.title == calendarName`, then pass
`[calendar]` to `predicateForEvents(withStart:end:calendars:)`. If no matching calendar
is found, return an error.

`list_calendars` lists **all** event calendars (`calendars(for: .event)`), regardless of
`CALENDAR_NAME` — matching the Go behaviour.

### `get_event` — trim whitespace on ID
Match the Go server: trim leading/trailing whitespace from the event ID before passing
to `EKEventStore.event(withIdentifier:)`.

### `list_events` — guard empty range
If `from >= to` after parsing, return an empty events array immediately (don't call
EventKit). Match the Go backend's early-return for invalid ranges.

### `parseRange` defaults
- `from` defaults to `Date()` (now)
- `to` defaults to `from + 24h`
- Error if `from >= to`

### Server identity fields
Match the Go `mcp.Implementation` exactly:
- Name: `"outlook-calendar"`
- Title: `"Outlook Calendar"`
- Version: `"0.1.0"`
- Description: `"Read-only access to calendars synced into macOS Calendar."`

### `calendar-local-probe` equivalent
The README documents `go run ./cmd/calendar-local-probe` as a direct JSON debugging
tool. It won't exist after the Swift rewrite. Update the README to remove that
reference and note that `list_events` via the Bob MCP panel serves the same purpose.

---

## What Is NOT Changing

- The 4 tool names and their JSON input/output schemas — identical to today
- `CALENDAR_NAME` env var — same behaviour
- `.bob/mcp.json` structure — only `command` path changes
- The Go source — left in place, not deleted (can be removed later)
