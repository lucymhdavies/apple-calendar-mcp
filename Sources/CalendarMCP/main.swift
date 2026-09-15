import Foundation
import MCP
import Darwin

enum ServerError: LocalizedError {
    case invalidRange
    case invalidDate(String)

    var errorDescription: String? {
        switch self {
        case .invalidRange: return "from must be before to"
        case .invalidDate(let field): return "parse \(field) as RFC3339 failed"
        }
    }
}

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
        let server = Server(name: "outlook-calendar", version: "0.1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: toolDefinitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let output = try await callTool(params, backend: backend, calendarName: calendarName)
                return .init(content: [.text(text: output)], isError: false)
            } catch {
                Log.message("tool \(params.name) failed: \(error.localizedDescription)")
                return .init(content: [.text(text: error.localizedDescription)], isError: true)
            }
        }

        try await server.start(transport: StdioTransport())
        try await Task.sleep(for: .seconds(365 * 24 * 3600))
    }
}

private let toolDefinitions = [
    Tool(name: "list_calendars", description: "List calendars available through the local macOS Calendar account.", inputSchema: .object(["type": .string("object"), "properties": .object([:])])),
    Tool(name: "list_events", description: "List calendar events overlapping a time range. Defaults to the next 24 hours.", inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "from": .object(["type": .string("string"), "description": .string("RFC3339 start time; defaults to now")]),
            "to": .object(["type": .string("string"), "description": .string("RFC3339 end time; defaults to 24 hours after from")]),
            "limit": .object(["type": .string("integer"), "description": .string("maximum number of events; defaults to 100")])
        ])
    ])),
    Tool(name: "get_event", description: "Get a calendar event by its Calendar.app event ID, including its full description and attendees.", inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["id": .object(["type": .string("string"), "description": .string("Calendar.app event ID")])]),
        "required": .array([.string("id")])
    ])),
    Tool(name: "get_freebusy", description: "Return busy slots derived from the local calendar. This does not query other people's availability.", inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "from": .object(["type": .string("string"), "description": .string("RFC3339 start time; defaults to now")]),
            "to": .object(["type": .string("string"), "description": .string("RFC3339 end time; defaults to 24 hours after from")]),
            "emails": .object([
                "type": .string("array"),
                "description": .string("optional email labels"),
                "items": .object(["type": .string("string")])
            ])
        ])
    ]))
]

private func callTool(_ params: CallTool.Parameters, backend: CalendarBackend, calendarName: String) async throws -> String {
    switch params.name {
    case "list_calendars":
        return try encode(["calendars": await backend.listCalendars()])
    case "list_events":
        let from = try dateArgument(params, key: "from") ?? Date()
        let to = try dateArgument(params, key: "to") ?? from.addingTimeInterval(24 * 60 * 60)
        try validateRange(from, to)
        var events = try await backend.listEvents(calendarName: calendarName, from: from, to: to)
        if let limit = intArgument(params, key: "limit"), limit > 0, events.count > limit { events = Array(events.prefix(limit)) }
        return try encode(["events": events])
    case "get_event":
        let id = stringArgument(params, key: "id") ?? ""
        return try encode(["event": try await backend.getEvent(calendarName: calendarName, id: id)])
    case "get_freebusy":
        let from = try dateArgument(params, key: "from") ?? Date()
        let to = try dateArgument(params, key: "to") ?? from.addingTimeInterval(24 * 60 * 60)
        try validateRange(from, to)
        let events = try await backend.listEvents(calendarName: calendarName, from: from, to: to)
        let slots = events.map { TimeSlot(start: $0.start, end: $0.end) }
        let emails = stringArrayArgument(params, key: "emails")
        let labels = emails.isEmpty ? [""] : emails
        let results = labels.map { FreeBusyResult(email: $0, availability: "local", busySlots: slots, source: "macos-calendar", note: "Derived from locally synced macOS Calendar; cross-user free/busy is unavailable.") }
        return try encode(["results": results])
    default:
        throw MCPError.invalidParams("unknown tool \(params.name)")
    }
}

private func dateArgument(_ params: CallTool.Parameters, key: String) throws -> Date? {
    guard let value = stringArgument(params, key: key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard let date = ISO8601DateFormatter().date(from: value) else { throw ServerError.invalidDate(key) }
    return date
}

private func validateRange(_ from: Date, _ to: Date) throws {
    guard from < to else { throw ServerError.invalidRange }
}

private func stringArgument(_ params: CallTool.Parameters, key: String) -> String? { params.arguments?[key]?.stringValue }
private func intArgument(_ params: CallTool.Parameters, key: String) -> Int? { params.arguments?[key]?.intValue }
private func stringArrayArgument(_ params: CallTool.Parameters, key: String) -> [String] { params.arguments?[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }

private func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}