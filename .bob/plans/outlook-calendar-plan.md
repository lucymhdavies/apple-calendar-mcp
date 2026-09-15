# Outlook Calendar REST API — Plan

## Top-Level Overview

Build a local-first calendar application that will expose a **read-only MCP server** for querying calendar data. A small Go command currently provides the local macOS Calendar bridge; the eventual MCP surface can be added on top of the same backend. The app supports backend modes, selectable at startup via an env var:

| Mode | Backend | Auth required | Data quality |
|------|---------|---------------|-------------|
| `macos` | macOS Calendar.app via AppleScript | Calendar.app account already signed in | Local synced events, descriptions, attendees, response status |
| `graph` | Microsoft Graph API (OAuth 2.0 Device Code) | IBM tenant approval required | Full — attendees, free/busy, real-time |
| `ics` | Published ICS feed URLs | Disabled/unavailable in the IBM Outlook tenant | Optional fallback only |

The mode is controlled by the `CALENDAR_BACKEND` env var (default: `macos`). In `ics` mode, one or more ICS feed URLs are provided via `ICS_FEED_URLS` (comma-separated).

Both modes use the same REST API surface and the same file-backed cache layer.

**Authentication status:** Graph Explorer works for this IBM account, but standalone Graph clients are blocked by IBM's `AADSTS65002` tenant preauthorization policy. The Microsoft Graph PowerShell, Azure CLI, Outlook, and Office public client IDs were all denied. Outlook ICS publishing is also unavailable. macOS Calendar.app is the working local source and requires no additional Graph consent.

**Non-goals:** no write/mutation endpoints, no multi-user auth, no production TLS, no Docker packaging, no reverse-engineering of Outlook's private cache.

---

## Architecture

```
cmd/server/main.go          ← entry point: select backend → start MCP/server
cmd/calendar-local-probe/   ← working macOS Calendar.app local reader
internal/auth/              ← Device Code flow, optional graph mode only
internal/backend/           ← Backend interface + factory
internal/backend/graph/     ← Microsoft Graph implementation
internal/backend/ics/       ← ICS feed implementation
internal/backend/macos/     ← macOS Calendar.app implementation
internal/types/             ← shared output structs (Calendar, Event, Attendee, etc.)
internal/cache/             ← in-memory store + JSON flush/load
internal/api/               ← chi router + HTTP handlers (backend-agnostic)
```

### Backend Interface

All handlers talk to a single `Backend` interface:

```go
type Backend interface {
    ListCalendars(ctx context.Context) ([]types.Calendar, error)
    ListEvents(ctx context.Context, from, to time.Time) ([]types.Event, error)
    GetEvent(ctx context.Context, id string) (*types.Event, error)
    GetFreeBusy(ctx context.Context, emails []string, from, to time.Time) ([]types.FreeBusyResult, error)
}
```

Shared types (`Calendar`, `Event`, `Attendee`, `FreeBusyResult`, `TimeSlot`) live in `internal/types/types.go`.

**Module path:** `github.com/lucymhdavies/outlook-calendar`
**Go version:** 1.22+
**Key dependencies:**
- `github.com/microsoftgraph/msgraph-sdk-go` — MS Graph SDK (graph mode)
- `github.com/Azure/azure-sdk-for-go/sdk/azidentity` — Device Code credential (graph mode)
- `github.com/arran4/golang-ical` — ICS parsing (ics mode)
- `github.com/go-chi/chi/v5` — HTTP router
- `github.com/go-chi/chi/v5/middleware` — logging, recovery

---

## Milestone 0 — Establish a Working Calendar Source

The original Graph login probe was tested, but IBM tenant policy blocks standalone public clients. The working source is the signed-in macOS Calendar.app account, accessed through its supported AppleScript interface.

**Done when:** The local probe returns synced events with IDs, times, descriptions, locations, and attendees. This is complete.

This milestone gates everything else. Once it works, Sub-Tasks 1–5 proceed in order.

---

## Sub-Tasks

---

### Sub-Task 1 — Prove Login (Milestone 0)

**Intent:** Confirm the Device Code flow works end-to-end with an IBM Microsoft 365 account using the well-known Graph PowerShell client ID, before building any application infrastructure.

**Expected Outcomes:**
- `cmd/login/main.go` compiles and runs
- Running it prints: `To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code XXXXXXXXX`
- After signing in with the IBM account, it prints the authenticated user's display name and email
- No Azure App Registration was required

**Todo List:**
1. Initialise `go.mod` with module path `github.com/lucymhdavies/outlook-calendar` and Go 1.22
2. `go get github.com/Azure/azure-sdk-for-go/sdk/azidentity` and `github.com/microsoftgraph/msgraph-sdk-go`
3. Create `cmd/login/main.go` that:
   - Creates a `DeviceCodeCredential` with client ID `14d82eec-204b-4c2f-b7e8-296a70dab67e`, tenant ID `common`, and a `UserPrompt` callback that prints the code and URL to stdout
   - Creates a Graph client with scopes `User.Read`, `Calendars.Read`, `offline_access`
   - Calls `GET /me` and prints `DisplayName` and `Mail`
   - Exits 0 on success, prints error and exits 1 on failure
4. Add a `.gitignore` covering `token.json`, `cache.json`, binaries, and `*.env`
5. **Human step:** Run `go run ./cmd/login`, complete the device code flow, confirm it works

**Relevant Context:**
- Well-known client ID: `14d82eec-204b-4c2f-b7e8-296a70dab67e` (Microsoft Graph PowerShell — publicly documented, no registration needed)
- Tenant ID `common` allows any Microsoft 365 account (work/school or personal)
- `azidentity.NewDeviceCodeCredential` takes `*DeviceCodeCredentialOptions` with `ClientID`, `TenantID`, and `UserPrompt func(DeviceCodeMessage)`
- `msgraphsdk.NewGraphServiceClientWithCredentials(cred, scopes)` constructs the Graph client
- The `UserPrompt` callback receives a `DeviceCodeMessage` with `Message` field — print it directly

**Status:** [x] complete via macOS Calendar.app; Graph path blocked by IBM policy

---

### Sub-Task 2 — Project Scaffolding

**Intent:** Establish the full directory layout and dependency manifest for the server application, building on the `go.mod` created in Sub-Task 1.

**Expected Outcomes:**
- Full directory tree exists: `cmd/server/`, `internal/auth/`, `internal/backend/graph/`, `internal/backend/ics/`, `internal/types/`, `internal/cache/`, `internal/api/`
- `internal/backend/backend.go` defines the `Backend` interface
- `internal/types/types.go` defines all shared output structs
- All four production dependencies are in `go.mod`/`go.sum`
- `cmd/server/main.go` compiles (stub that prints "not yet implemented")
- `go build ./...` succeeds with no errors

**Todo List:**
1. Add remaining dependencies: `github.com/arran4/golang-ical`, `github.com/go-chi/chi/v5`
2. Create the directory tree (stub `.go` files with correct `package` declarations)
3. Write `internal/backend/backend.go` — `Backend` interface definition only
4. Write `internal/types/types.go` — `Calendar`, `Event`, `Attendee`, `FreeBusyResult`, `TimeSlot` structs with JSON tags
5. Write stub `cmd/server/main.go` that imports packages and prints "not yet implemented"

**Relevant Context:**
- `cmd/login/main.go` already exists from Sub-Task 1; do not modify it
- Keep the `Backend` interface in `internal/backend/` so both `graph` and `ics` sub-packages can implement it without circular imports

**Status:** [x] complete; dependencies, scaffold, shared interface, and types exist and `go test ./...` passes

---

### Sub-Task 2A — macOS Calendar Backend

**Intent:** Use the signed-in macOS Calendar account as the primary local data source, avoiding Graph consent and Outlook's private cache format.

**Verified behavior:** `cmd/calendar-local-probe` invokes Calendar.app through AppleScript and returns JSON event records. Calendar.app exposes event IDs, titles, descriptions, locations, start/end times, all-day state, URLs, recurrence/status metadata, and attendee email/name/participation status.

**Todo List:**
1. Move the proven AppleScript bridge behind `internal/backend/macos/` and the shared `Backend` interface.
2. Add calendar selection and bounded date-window filtering with defensive Go-side filtering for recurring-event anomalies.
3. Implement `GetEvent` by Calendar.app event ID.
4. Define free/busy as derived busy slots from local events; document that cross-user schedule lookup is unavailable.
5. Add focused tests for AppleScript row parsing and attendee parsing.

**Status:** [x] complete; macOS backend, event lookup, derived free/busy, and parser/script tests implemented

---

### Sub-Task 3 — Auth Package and Graph Backend

**Intent:** Implement the production auth layer (token persistence across restarts) and the full Graph backend that satisfies the `Backend` interface.

**Expected Outcomes:**
- `internal/auth/auth.go` handles Device Code flow with token persistence to `~/.outlook-calendar/token.json` and auto-refresh on subsequent runs
- `internal/backend/graph/graph.go` implements all four `Backend` interface methods against the live Graph API
- The well-known client ID is the default; `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` env vars override it

**Todo List:**
1. Create `internal/auth/auth.go`:
   - `New(ctx) (*Auth, error)` — loads token cache from `~/.outlook-calendar/token.json` if present, otherwise initiates Device Code flow
   - Uses `azidentity.TokenCachePersistenceOptions` (or manual serialisation) to persist the token cache
   - Exports `GraphClient() (*msgraphsdk.GraphServiceClient, error)`
   - Reads `AZURE_CLIENT_ID` (default `14d82eec-204b-4c2f-b7e8-296a70dab67e`) and `AZURE_TENANT_ID` (default `common`) from env
2. Create `internal/backend/graph/graph.go` implementing `Backend`:
   - `ListCalendars`: `client.Me().Calendars().Get(ctx, nil)`
   - `ListEvents`: `client.Me().CalendarView().Get(ctx, opts)` with `startDateTime`/`endDateTime` query params
   - `GetEvent`: `client.Me().Events().ByEventId(id).Get(ctx, nil)`
   - `GetFreeBusy`: `client.Me().Calendar().GetSchedule().Post(ctx, body, nil)`
3. Map all Graph SDK model fields to `internal/types` structs; handle nil pointer fields defensively

**Relevant Context:**
- Graph SDK models in `github.com/microsoftgraph/msgraph-sdk-go/models`
- `CalendarView` is preferred over per-calendar `Events` filtering — it returns events from all calendars in one call, honouring the time window
- `GetSchedule` returns per-email availability; collect all items from the response
- Required scopes: `Calendars.Read`, `User.Read`, `offline_access`
- Token cache file path: `~/.outlook-calendar/token.json`

**Status:** [ ] optional; blocked for this IBM tenant until an Entra app is preauthorized

---

### Sub-Task 4 — ICS Backend

**Intent:** Implement the ICS feed backend as the secondary mode, mapping published ICS URLs to the same `Backend` interface.

**Expected Outcomes:**
- `internal/backend/ics/ics.go` implements the `Backend` interface
- `ListCalendars` returns one synthetic entry per configured feed URL
- `ListEvents` fetches, parses, and filters events by time window client-side
- `GetEvent` looks up by `UID` across all feeds
- `GetFreeBusy` returns derived busy slots from events with a note that cross-user free/busy is unavailable in ICS mode
- Feed URLs are read from `ICS_FEED_URLS` env var; startup fails clearly if unset in `ics` mode

**Todo List:**
1. Create `internal/backend/ics/ics.go` with a struct holding feed URLs
2. Fetch feeds with `net/http` (30s timeout); use `If-None-Match`/`If-Modified-Since` to skip unchanged feeds
3. Parse with `github.com/arran4/golang-ical`; map `VEVENT` fields to `internal/types` structs defensively
4. Filter events: include where `Start < to && End > from`
5. Implement `GetFreeBusy` as derived busy-slot list; add `source:"ics"` and `note` field to response

**Relevant Context:**
- ICS feeds have no server-side date filter — always download full feed and filter locally
- `ATTENDEE`/`ORGANIZER` fields are optional — handle absence gracefully
- Feed URLs are secrets — never log them

**Status:** [ ] optional fallback; Outlook ICS publishing is unavailable in the current IBM tenant

---

### Sub-Task 5 — File-Backed Cache

**Intent:** Provide a cache layer shared by both backends that persists across restarts.

**Expected Outcomes:**
- `internal/cache/cache.go` exposes `New(path string, ttl time.Duration) *Cache`
- `Get(key string) ([]byte, bool)`, `Set(key string, data []byte)`, `Invalidate(key string)`
- Thread-safe; disk flush is asynchronous (fire-and-forget goroutine)
- On startup, loads existing non-expired entries from `~/.outlook-calendar/cache.json`
- Unit tests in `internal/cache/cache_test.go` cover get/set/expiry/reload

**Todo List:**
1. Write `internal/cache/cache.go` with struct, `New`, `Get`, `Set`, `Invalidate`
2. Persist format: JSON object, each entry has `data` (base64) and `expires_at` (RFC3339)
3. Write `internal/cache/cache_test.go`

**Relevant Context:** stdlib only — `encoding/json`, `sync`, `os`.

**Status:** [ ] pending; shared cache may be unnecessary for the local-first MCP design

---

### Sub-Task 6 — REST API Handlers, Router, and Server Wiring

**Intent:** Wire up the HTTP layer and complete `cmd/server/main.go` so the app is fully runnable.

**Expected Outcomes:**

| Method | Path | Query params | Description |
|--------|------|-------------|-------------|
| GET | `/calendars` | — | List all calendars |
| GET | `/events` | `from`, `to` (RFC3339, optional; default today) | List events across all calendars |
| GET | `/events/{id}` | — | Single event detail including attendees |
| GET | `/freebusy` | `from`, `to` (RFC3339, optional; default today), `emails` (comma-separated, optional) | Free/busy schedule |
| GET | `/health` | — | Returns `{"status":"ok","backend":"ics\|graph"}` |

- All responses JSON; errors return `{"error":"..."}` with appropriate HTTP status
- Cache key = request path + sorted query string
- chi middleware: `Logger`, `Recoverer`, `RealIP`
- `cmd/server/main.go` reads `CALENDAR_BACKEND` (default `graph`), constructs backend + cache, starts `http.ListenAndServe("127.0.0.1:8080", router)`

**Todo List:**
1. Write `internal/api/router.go` — accepts `Backend` and `*Cache`, returns chi router
2. Write `internal/api/handlers.go` — one handler per endpoint; all backend-agnostic
3. Write `internal/api/helpers.go` — `parseTimeParam`, `jsonError`, `cacheKey`
4. Complete `cmd/server/main.go` — backend selection, dependency wiring, server start
5. Env vars: `PORT` (default `8080`), `CACHE_TTL_SECONDS` (default `300`), `CALENDAR_BACKEND` (default `macos`)

**Status:** [x] MCP stdio server and four read-only tools implemented; initialize/tools-list handshake verified

---

### Sub-Task 7 — README and Configuration Guide

**Intent:** Document how to run the app, both modes, all env vars, and all endpoints.

**Expected Outcomes:**
- `README.md` covers: prerequisites, how Device Code login works (no registration needed), how to get an ICS feed URL from Outlook on the Web, all env vars, all endpoints with example `curl` commands, where token/cache files live, known ICS limitations

**Todo List:**
1. Write `README.md` with all sections above
2. Document: `CALENDAR_BACKEND`, `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `ICS_FEED_URLS`, `PORT`, `CACHE_TTL_SECONDS`
3. Explain the well-known client ID approach and why no App Registration is needed
4. Add ICS feed publishing instructions (Outlook on the Web → Settings → Calendar → Shared calendars → Publish)
5. Add example curl commands for every endpoint
6. Note ICS limitations: stale data, no cross-user free/busy, attendees may be absent

**Status:** [x] VS Code/Bob MCP configuration and README added; client-side activation remains environment-dependent

---

## Dependency Versions (to pin at scaffold time)

| Package | Purpose |
|---------|---------|
| `github.com/microsoftgraph/msgraph-sdk-go` | MS Graph API client (graph mode) |
| `github.com/Azure/azure-sdk-for-go/sdk/azidentity` | Device Code credential + token cache (graph mode) |
| `github.com/arran4/golang-ical` | ICS feed parsing (ics mode) |
| `github.com/go-chi/chi/v5` | HTTP router |

All other code uses Go stdlib only.
