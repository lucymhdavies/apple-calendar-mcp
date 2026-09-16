import Foundation
import MCP

struct CalendarService {
    let backend: CalendarBackend
    let calendarName: String

    func listCalendars() async -> [CalendarInfo] {
        await backend.listCalendars()
    }

    func listEvents(from: String?, to: String?, limit: Int?) async throws -> [CalendarEvent] {
        let start = try date(from, field: "from") ?? Date()
        let end = try date(to, field: "to") ?? start.addingTimeInterval(24 * 60 * 60)
        try validateRange(start, end)

        var events = try await backend.listEvents(calendarName: calendarName, from: start, to: end)
        if let limit, limit > 0, events.count > limit {
            events = Array(events.prefix(limit))
        }
        return events
    }

    func getEvent(id: String?) async throws -> CalendarEvent {
        try await backend.getEvent(calendarName: calendarName, id: id ?? "")
    }

    func getFreeBusy(from: String?, to: String?, emails: [String]) async throws -> [FreeBusyResult] {
        let start = try date(from, field: "from") ?? Date()
        let end = try date(to, field: "to") ?? start.addingTimeInterval(24 * 60 * 60)
        try validateRange(start, end)

        let events = try await backend.listEvents(calendarName: calendarName, from: start, to: end)
        let slots = events.map { TimeSlot(start: $0.start, end: $0.end) }
        let labels = emails.isEmpty ? [""] : emails
        return labels.map {
            FreeBusyResult(
                email: $0,
                availability: "local",
                busySlots: slots,
                source: "macos-calendar",
                note: "Derived from locally synced macOS Calendar; cross-user free/busy is unavailable.")
        }
    }

    private func date(_ value: String?, field: String) throws -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let parsed = ISO8601DateFormatter().date(from: value) else {
            throw ServerError.invalidDate(field)
        }
        return parsed
    }
}

func dateArgument(_ params: CallTool.Parameters, key: String) throws -> Date? {
    try parseDate(params.arguments?[key]?.stringValue, field: key)
}

private func parseDate(_ value: String?, field: String) throws -> Date? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    guard let parsed = ISO8601DateFormatter().date(from: value) else {
        throw ServerError.invalidDate(field)
    }
    return parsed
}

func validateRange(_ from: Date, _ to: Date) throws {
    guard from < to else { throw ServerError.invalidRange }
}

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
