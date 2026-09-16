# Changelog

All notable changes to this project will be documented here.

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
