# Calendar REST API

This is the HTTP API exposed by the packaged `CalendarAPI` macOS application.
It is read-only and serves events from the local macOS Calendar account selected
by `CALENDAR_NAME` (default: `Calendar`).

## Base URL and authentication

The default base URL is `http://127.0.0.1:8765`. The server is disabled unless
started with `REST_ENABLED=true` or `--rest`. When running as a menu bar app,
use **Configure API Port...** to change the port; the choice is persisted in
`UserDefaults` and takes precedence over `REST_PORT` on later launches. Use
**Calendar: ...** in the menu bar to choose the Calendar.app calendar served by
the API; that choice is also persisted.

When LAN exposure is enabled, the app also publishes a Bonjour service named
`CalendarAPI` with type `_http._tcp`. Clients can browse for that service and
use the resolved host and port as the API base URL. Loopback-only mode is not
advertised. Bonjour discovery does not bypass bearer-token authentication.

Loopback mode does not require authentication. When the server is exposed to
the LAN, every request except `GET /health` must include:

```http
Authorization: Bearer YOUR_API_KEY
```

The API key is generated and stored in the macOS Keychain when LAN exposure is
enabled. A manually configured non-loopback listener requires `REST_TOKEN` with
at least 16 characters.

All successful and error responses use `Content-Type: application/json`.

## Backend integration

For a browser application, discovery should happen in the calling service's
backend rather than in frontend JavaScript. The backend should:

1. Browse for `CalendarAPI._http._tcp.local` using Bonjour/DNS-SD.
2. Resolve the discovered service to its current host and port.
3. Send the bearer token when calling endpoints other than `/health`.
4. Proxy or normalize the response through the calling service's own API.

This keeps the CalendarAPI token server-side and avoids browser limitations: web
pages cannot browse Bonjour services directly, and CalendarAPI does not need to
enable CORS for an unrelated frontend origin.

The service has no required TXT record. The resolved host and port are the
connection details; the API key is separate authentication material.

## Endpoints

### `GET /health`

Unauthenticated liveness check.

Response:

```json
{"status":"ok","service":"calendar"}
```

### `GET /v1/calendars`

Lists event calendars visible to Calendar.app.

Response:

```json
{
  "calendars": [
    {
      "id": "calendar-id",
      "name": "Calendar",
      "description": "",
      "color": "",
      "can_edit": true
    }
  ]
}
```

`description` and `color` are currently empty strings because EventKit does not
map them in this API.

### `GET /v1/events`

Lists events overlapping a time range.

Query parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `from` | No | RFC3339/ISO 8601 start time; defaults to the current time. |
| `to` | No | RFC3339/ISO 8601 end time; defaults to 24 hours after `from`. |
| `limit` | No | Positive integer maximum number of returned events. If omitted, zero, or negative, no limit is applied. |

Response:

```json
{"events":[{"id":"event-id","calendar_id":"calendar-id","subject":"Planning","body":"","start":"2026-09-16T12:00:00Z","end":"2026-09-16T13:00:00Z","location":"","is_all_day":false,"organizer":"","attendees":[],"web_link":"","recurrence":"","status":"confirmed"}]}
```

Events are returned for the configured `CALENDAR_NAME` calendar only. Use URL
encoding for event IDs and other query values.

### `GET /v1/events?id={event_id}`

Returns one event by its Calendar.app event ID. The `id` parameter selects this
form of the endpoint and is required for a single-event lookup.

Response:

```json
{"event":{"id":"event-id","calendar_id":"calendar-id","subject":"Planning","body":"","start":"2026-09-16T12:00:00Z","end":"2026-09-16T13:00:00Z","location":"","is_all_day":false,"organizer":"","attendees":[],"web_link":"","recurrence":"","status":"confirmed"}}
```

Each attendee has `name`, `email`, `type`, and `status`. Attendee status is one
of `accepted`, `declined`, `tentative`, or `unknown`. Event status is one of
`confirmed`, `tentative`, `cancelled`, or `none`.

### `GET /v1/freebusy`

Derives busy slots from events in the local calendar. It does not query other
people's availability.

Query parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `from` | No | RFC3339/ISO 8601 start time; defaults to the current time. |
| `to` | No | RFC3339/ISO 8601 end time; defaults to 24 hours after `from`. |
| `email` | No | Repeatable label for a result, for example `?email=a@example.com&email=b@example.com`. |

If no `email` is supplied, one result is returned with an empty `email`.

Response:

```json
{
  "results": [
    {
      "email": "a@example.com",
      "availability": "local",
      "busy_slots": [
        {"start":"2026-09-16T12:00:00Z","end":"2026-09-16T13:00:00Z"}
      ],
      "source": "macos-calendar",
      "note": "Derived from locally synced macOS Calendar; cross-user free/busy is unavailable."
    }
  ]
}
```

## Errors

Errors have this shape:

```json
{"error":"from must be before to"}
```

| Status | Meaning |
| --- | --- |
| `400` | Malformed request, invalid RFC3339 date, invalid range, missing event ID, or another calendar request error. |
| `401` | Missing or incorrect bearer token when authentication is enabled. |
| `404` | Unknown route, calendar, or event. |
| `500` | Server or configuration failure. |

Date ranges must satisfy `from < to`. Query parameters may be omitted to use
the defaults above.

## Example

```bash
BASE_URL=http://127.0.0.1:8765
curl "$BASE_URL/health"
curl "$BASE_URL/v1/calendars"
curl "$BASE_URL/v1/events?from=2026-09-16T00:00:00Z&to=2026-09-17T00:00:00Z&limit=20"
curl "$BASE_URL/v1/freebusy?from=2026-09-16T00:00:00Z&to=2026-09-17T00:00:00Z"
```