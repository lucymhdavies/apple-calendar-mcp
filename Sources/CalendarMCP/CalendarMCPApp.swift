import AppKit
import Darwin
import Foundation
import MCP

@main
struct CalendarMCP {
    static func main() async {
        do {
            try await run()
        } catch {
            Log.message("server startup failed: \(error.localizedDescription)")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        Log.startupDiagnostics()
        let calendarName = ProcessInfo.processInfo.environment["CALENDAR_NAME"] ?? "Calendar"

        if RESTConfiguration.isEnabled {
            // In REST/menu-bar mode, request access after NSApplication launches
            // so macOS can show the permission dialog (requires a window server connection).
            let configuration = try RESTConfiguration.fromEnvironment()
            let backend = CalendarBackend()
            let service = CalendarService(backend: backend, calendarName: calendarName)
            await runMenuBar(service: service, backend: backend, configuration: configuration)
            return
        }

        let service: CalendarService
        let usingEventKit: Bool
        let eventKitBackend = CalendarBackend()
        do {
            try await eventKitBackend.requestAccess()
            service = CalendarService(backend: eventKitBackend, calendarName: calendarName)
            usingEventKit = true
        } catch {
            Log.message("calendar access denied: \(error.localizedDescription)")
            Log.message("attempting REST fallback via Bonjour...")
            let restBackend = RESTBackend()
            do {
                try await restBackend.checkReachable()
            } catch {
                Log.message("REST fallback unavailable: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
            service = CalendarService(backend: restBackend, calendarName: calendarName)
            usingEventKit = false
        }

        let version = Bundle.main.infoDictionary?["CalendarMCPBuildRevision"] as? String
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        let server = Server(
            name: "calendar-api", version: version, capabilities: .init(tools: .init()))

        let backendType = usingEventKit ? "eventkit" : "rest"

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: toolDefinitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let output = try await callTool(
                    params,
                    service: service,
                    version: version,
                    backendType: backendType)
                return .init(
                    content: [.text(text: output, annotations: nil, _meta: nil)], isError: false)
            } catch {
                Log.message("tool \(params.name) failed: \(error.localizedDescription)")
                return .init(
                    content: [
                        .text(text: error.localizedDescription, annotations: nil, _meta: nil)
                    ], isError: true)
            }
        }

        try await server.start(transport: StdioTransport())
        try await Task.sleep(for: .seconds(365 * 24 * 3600))
    }

    @MainActor
    private static func runMenuBar(
        service: CalendarService, backend: CalendarBackend, configuration: RESTConfiguration
    ) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = MenuBarController(
            service: service, backend: backend, configuration: configuration)
        application.delegate = delegate
        application.run()
    }
}

private let toolDefinitions = [
    Tool(
        name: "list_calendars",
        description: "List calendars available through the local macOS Calendar account.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
    Tool(
        name: "list_events",
        description:
            "List calendar events overlapping a time range with minimal details (subject, time, organizer, location). Use get_event to retrieve full details including attendees and description.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "from": .object([
                    "type": .string("string"),
                    "description": .string("RFC3339 start time; defaults to now"),
                ]),
                "to": .object([
                    "type": .string("string"),
                    "description": .string("RFC3339 end time; defaults to 24 hours after from"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("maximum number of events; defaults to 100"),
                ]),
            ]),
        ])),
    Tool(
        name: "get_event",
        description:
            "Get a calendar event by its Calendar.app event ID, including its full description and attendees.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"), "description": .string("Calendar.app event ID"),
                ])
            ]),
            "required": .array([.string("id")]),
        ])),
    Tool(
        name: "get_freebusy",
        description:
            "Return busy slots derived from the local calendar. This does not query other people's availability.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "from": .object([
                    "type": .string("string"),
                    "description": .string("RFC3339 start time; defaults to now"),
                ]),
                "to": .object([
                    "type": .string("string"),
                    "description": .string("RFC3339 end time; defaults to 24 hours after from"),
                ]),
                "emails": .object([
                    "type": .string("array"),
                    "description": .string("optional email labels"),
                    "items": .object(["type": .string("string")]),
                ]),
            ]),
        ])),
    Tool(
        name: "debug_info",
        description:
            "Get diagnostic information about the MCP server and backend connection status. Useful for debugging calendar access issues.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
]

private func callTool(
    _ params: CallTool.Parameters,
    service: CalendarService,
    version: String,
    backendType: String) async throws -> String
{
    switch params.name {
    case "debug_info":
        let info: [String: String] = [
            "version": version,
            "backend": backendType,
            "note": backendType == "eventkit"
                ? "Using direct EventKit access to local macOS Calendar"
                : "Using REST fallback via Bonjour to communicate with local Calendar API"
        ]
        return try encode(info)
    case "list_calendars":
        return try encode(["calendars": await service.listCalendars()])
    case "list_events":
        let events = try await service.listEventsSummaries(
            from: stringArgument(params, key: "from"),
            to: stringArgument(params, key: "to"),
            limit: intArgument(params, key: "limit"))
        return try encode(["events": events])
    case "get_event":
        let id = stringArgument(params, key: "id") ?? ""
        return try encode(["event": try await service.getEvent(id: id)])
    case "get_freebusy":
        let results = try await service.getFreeBusy(
            from: stringArgument(params, key: "from"),
            to: stringArgument(params, key: "to"),
            emails: stringArrayArgument(params, key: "emails"))
        return try encode(["results": results])
    default:
        throw MCPError.invalidParams("unknown tool \(params.name)")
    }
}

private func stringArgument(_ params: CallTool.Parameters, key: String) -> String? {
    params.arguments?[key]?.stringValue
}
private func intArgument(_ params: CallTool.Parameters, key: String) -> Int? {
    params.arguments?[key]?.intValue
}
private func stringArrayArgument(_ params: CallTool.Parameters, key: String) -> [String] {
    params.arguments?[key]?.arrayValue?.compactMap(\.stringValue) ?? []
}

private func encode<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try restJSONEncoder().encode(value), as: UTF8.self)
}
