# Changelog

All notable changes to this project will be documented here.

## [0.1.4] - 2026-09-18

### Fixed

- `/v1/calendars` (and the `list_calendars` MCP tool) could return an empty calendar list even after calendar access was granted in menu-bar/REST mode. The backend's `EKEventStore` was created before access was granted, and EventKit keeps serving an empty cache from a store created in that state; the menu bar's permission flow also requested access through a separate, throwaway store, so the backend's store was never refreshed. The backend now recreates its store immediately after access is granted.

### Added

- A "Serving: ..." menu bar item showing the calendar currently served by the API, with a warning state (and warning status icon) when calendar access is missing, no calendars are found, or the configured calendar no longer exists.

## [0.1.3] - 2026-09-18

### Fixed

- The menu bar app's calendar access request hung indefinitely ("Calendar Access: checking..."), which also broke the stdio MCP server's REST fallback. The cause: this SwiftPM `@main async` executable's main libdispatch queue is never serviced while `NSApplication.run()` is spinning its run loop, so `Task {}`/`DispatchQueue.main.async` work scheduled after launch silently never executed. The calendar access flow, REST server running-state updates, and the calendar picker now marshal back to the main thread via `RunLoop.main.perform` instead.
- The app now activates itself (`NSApp.activate`) before requesting calendar access so the system permission prompt reliably appears for LaunchAgent-launched/accessory-mode instances.

### Added

- Startup diagnostics (pid/ppid/launch context, bundle path, code-signing identity) and detailed calendar-authorization logging to `~/Library/Logs/CalendarMCP` to aid future TCC/permission debugging.

## [0.1.2] - 2026-09-16

### Added

- CalendarAPI public naming for the app, MCP registration, logs, and Bonjour service.
- Bonjour `_http._tcp` discovery for LAN clients without a fixed port.
- Menu-bar configuration for the API port and selected calendar.
- API documentation for backend services that discover CalendarAPI and proxy requests to it.

### Changed

- The MCP transport is documented as one mode of the broader CalendarAPI service.

## [0.1.1] - 2026-09-16

### Added

- Persisted LAN exposure preference and Keychain-backed API key management.
- Distinct menu bar status for local and LAN-exposed API modes.
- Login startup through a per-user LaunchAgent.

### Fixed

- Menu bar running state now follows the active REST listener.
- Documented LAN authentication and login startup behavior.

## [0.1.0] - 2026-09-16

### Added

- Swift EventKit MCP server for macOS Calendar data.
- Read-only REST API with health, calendars, events, and free/busy endpoints.
- Optional macOS menu bar application for controlling the REST server.
- Loopback-by-default REST binding with bearer-token protection for LAN binding.
- Unit tests and macOS CI for Swift tests and release builds.
