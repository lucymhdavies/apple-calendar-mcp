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
        let backend = CalendarBackend()
        do {
            try await backend.requestAccess()
        } catch {
            Log.message("calendar access denied: \(error.localizedDescription)")
            Darwin.exit(EXIT_FAILURE)
        }

        let calendarName = ProcessInfo.processInfo.environment["CALENDAR_NAME"] ?? "Calendar"
        let service = CalendarService(backend: backend, calendarName: calendarName)
        if RESTConfiguration.isEnabled {
            let configuration = try RESTConfiguration.fromEnvironment()
            await runMenuBar(service: service, configuration: configuration)
            return
        }

        let server = Server(
            name: "calendar-api", version: "0.1.2", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: toolDefinitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let output = try await callTool(params, service: service)
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
    private static func runMenuBar(service: CalendarService, configuration: RESTConfiguration) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = MenuBarController(service: service, configuration: configuration)
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
            "List calendar events overlapping a time range. Defaults to the next 24 hours.",
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
]

private func callTool(_ params: CallTool.Parameters, service: CalendarService) async throws
    -> String
{
    switch params.name {
    case "list_calendars":
        return try encode(["calendars": await service.listCalendars()])
    case "list_events":
        let events = try await service.listEvents(
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
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
