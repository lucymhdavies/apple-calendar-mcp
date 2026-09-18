import EventKit
import Foundation

enum CalendarBackendError: LocalizedError {
    case accessDenied
    case accessNotDetermined
    case calendarNotFound(String)
    case eventNotFound(String)
    case eventIDRequired

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Calendar access was denied"
        case .accessNotDetermined: return "Calendar access has not been granted. Open System Settings → Privacy & Security → Calendars and enable access for CalendarMCP, then restart the MCP server."
        case .calendarNotFound(let name): return "calendar \(name.inspect) not found"
        case .eventNotFound(let id): return "event \(id.inspect) not found"
        case .eventIDRequired: return "event ID is required"
        }
    }
}

private final class AuthorizationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ granted: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: granted)
    }
}

actor CalendarBackend: CalendarDataSource {
    private let store = EKEventStore()

    func requestAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        Log.message("calendar authorization status at request time: \(status.diagnosticName)")
        switch status {
        case .fullAccess:
            Log.message("calendar access already granted")
            return
        case .writeOnly:
            Log.message("calendar access is write-only; full access is required for calendar reads")
            throw CalendarBackendError.accessDenied
        case .denied, .restricted:
            Log.message(
                "calendar access previously denied/restricted — the system will not re-prompt; grant access manually in System Settings > Privacy & Security > Calendars"
            )
            throw CalendarBackendError.accessDenied
        case .notDetermined:
            Log.message(
                "calendar access not determined — calling requestFullAccessToEvents (macOS should show a permission prompt now)"
            )
            let start = Date()
            let granted = await withCheckedContinuation { continuation in
                let completion = AuthorizationCompletion(continuation)
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    completion.resume(false)
                }
                store.requestFullAccessToEvents { granted, error in
                    if let error {
                        Log.message("requestFullAccessToEvents returned an error: \(error.localizedDescription)")
                    }
                    completion.resume(granted)
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            Log.message(
                "requestFullAccessToEvents resolved granted=\(granted) after \(String(format: "%.1f", elapsed))s"
            )
            guard granted else { throw CalendarBackendError.accessNotDetermined }
            Log.message("calendar access granted")
        @unknown default:
            Log.message("calendar authorization status is unrecognized (@unknown default)")
            throw CalendarBackendError.accessDenied
        }
    }

    func listCalendars() -> [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, name: $0.title, description: "", color: "", canEdit: $0.allowsContentModifications)
        }
    }

    func listEvents(calendarName: String, from: Date, to: Date) throws -> [CalendarEvent] {
        guard from < to else { return [] }
        let calendar = try calendar(named: calendarName)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate).map(makeEvent)
    }

    func getEvent(calendarName: String, id: String) throws -> CalendarEvent {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw CalendarBackendError.eventIDRequired }
        _ = try calendar(named: calendarName)
        guard let event = store.event(withIdentifier: trimmedID), event.calendar.title == calendarName else {
            throw CalendarBackendError.eventNotFound(trimmedID)
        }
        return makeEvent(event)
    }

    private func calendar(named name: String) throws -> EKCalendar {
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == name }) else {
            throw CalendarBackendError.calendarNotFound(name)
        }
        return calendar
    }

    private func makeEvent(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarID: event.calendar.calendarIdentifier,
            subject: event.title ?? "",
            body: event.notes ?? "",
            start: event.startDate,
            end: event.endDate,
            location: event.location ?? "",
            isAllDay: event.isAllDay,
            organizer: event.organizer?.name ?? "",
            attendees: (event.attendees ?? []).map {
                Attendee(name: $0.name ?? "", email: $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""), type: "", status: participantStatus($0.participantStatus))
            },
            webLink: event.url?.absoluteString ?? "",
            recurrence: "",
            status: eventStatus(event.status)
        )
    }

    private func participantStatus(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        default: return "unknown"
        }
    }

    private func eventStatus(_ status: EKEventStatus) -> String {
        switch status {
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "cancelled"
        default: return "none"
        }
    }
}

private extension String {
    var inspect: String { "\"\(self.replacingOccurrences(of: "\"", with: "\\\""))\"" }
}

extension EKAuthorizationStatus {
    var diagnosticName: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}