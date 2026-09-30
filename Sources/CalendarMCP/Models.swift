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
    let category: EventCategory

    enum CodingKeys: String, CodingKey {
        case id, subject, body, start, end, location, organizer, attendees, recurrence, status, category
        case calendarID = "calendar_id"
        case isAllDay = "is_all_day"
        case webLink = "web_link"
    }

    init(
        id: String, calendarID: String, subject: String, body: String, start: Date, end: Date,
        location: String, isAllDay: Bool, organizer: String, attendees: [Attendee],
        webLink: String, recurrence: String, status: String,
        category: EventCategory = .uncategorized
    ) {
        self.id = id
        self.calendarID = calendarID
        self.subject = subject
        self.body = body
        self.start = start
        self.end = end
        self.location = location
        self.isAllDay = isAllDay
        self.organizer = organizer
        self.attendees = attendees
        self.webLink = webLink
        self.recurrence = recurrence
        self.status = status
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        calendarID = try container.decode(String.self, forKey: .calendarID)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        location = try container.decode(String.self, forKey: .location)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        organizer = try container.decode(String.self, forKey: .organizer)
        attendees = try container.decode([Attendee].self, forKey: .attendees)
        webLink = try container.decode(String.self, forKey: .webLink)
        recurrence = try container.decode(String.self, forKey: .recurrence)
        status = try container.decode(String.self, forKey: .status)
        category = try container.decodeIfPresent(EventCategory.self, forKey: .category) ?? .uncategorized
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
            webLink: webLink,
            category: category
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
    let category: EventCategory

    enum CodingKeys: String, CodingKey {
        case id, subject, start, end, location, organizer, category
        case calendarID = "calendar_id"
        case isAllDay = "is_all_day"
        case webLink = "web_link"
    }

    init(
        id: String, calendarID: String, subject: String, start: Date, end: Date,
        location: String, isAllDay: Bool, organizer: String, webLink: String,
        category: EventCategory = .uncategorized
    ) {
        self.id = id
        self.calendarID = calendarID
        self.subject = subject
        self.start = start
        self.end = end
        self.location = location
        self.isAllDay = isAllDay
        self.organizer = organizer
        self.webLink = webLink
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        calendarID = try container.decode(String.self, forKey: .calendarID)
        subject = try container.decode(String.self, forKey: .subject)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        location = try container.decode(String.self, forKey: .location)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        organizer = try container.decode(String.self, forKey: .organizer)
        webLink = try container.decode(String.self, forKey: .webLink)
        category = try container.decodeIfPresent(EventCategory.self, forKey: .category) ?? .uncategorized
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