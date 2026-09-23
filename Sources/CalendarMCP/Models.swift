import Foundation

struct CalendarInfo: Codable {
    let id: String
    let name: String
    let description: String
    let color: String
    let canEdit: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, color
        case canEdit = "can_edit"
    }
}

struct Attendee: Codable {
    let name: String
    let email: String
    let type: String
    let status: String
}

struct CalendarEvent: Codable {
    let id: String
    let calendarID: String
    let subject: String
    let body: String
    let start: Date
    let end: Date
    let location: String
    let isAllDay: Bool
    let organizer: String
    let attendees: [Attendee]
    let webLink: String
    let recurrence: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, subject, body, start, end, location, organizer, attendees, recurrence, status
        case calendarID = "calendar_id"
        case isAllDay = "is_all_day"
        case webLink = "web_link"
    }

    /// Returns a summary version with minimal details (excludes body and attendees)
    func toSummary() -> CalendarEventSummary {
        CalendarEventSummary(
            id: id,
            calendarID: calendarID,
            subject: subject,
            start: start,
            end: end,
            location: location,
            isAllDay: isAllDay,
            organizer: organizer,
            webLink: webLink
        )
    }
}

/// Minimal event summary for list operations (excludes body and attendees to reduce payload)
struct CalendarEventSummary: Codable {
    let id: String
    let calendarID: String
    let subject: String
    let start: Date
    let end: Date
    let location: String
    let isAllDay: Bool
    let organizer: String
    let webLink: String

    enum CodingKeys: String, CodingKey {
        case id, subject, start, end, location, organizer
        case calendarID = "calendar_id"
        case isAllDay = "is_all_day"
        case webLink = "web_link"
    }
}

struct TimeSlot: Codable {
    let start: Date
    let end: Date
}

struct FreeBusyResult: Codable {
    let email: String
    let availability: String
    let busySlots: [TimeSlot]
    let source: String
    let note: String

    enum CodingKeys: String, CodingKey {
        case email, availability, source, note
        case busySlots = "busy_slots"
    }
}