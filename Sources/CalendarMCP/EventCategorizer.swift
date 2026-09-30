import Foundation

enum EventCategory: String, Codable, CaseIterable {
    case oneOnOne = "one-on-one"
    case external
    case focusTime = "focus-time"
    case hold
    case `internal`
    case outOfOffice = "out-of-office"
    case travel
    case uncategorized
}

struct EventCategorizationContext {
    let title: String
    let isAllDay: Bool
    let isCalendarWritable: Bool
    let isCurrentUserOrganizer: Bool
    let hasOrganizer: Bool
    let otherParticipantCount: Int
    let participantDomains: Set<String>
    let currentUserDomains: Set<String>

    var isPersonalEvent: Bool {
        otherParticipantCount == 0
            && (isCurrentUserOrganizer || (!hasOrganizer && isCalendarWritable))
    }
}

enum EventCategorizer {
    private static let absencePattern = #"\b(ooo|pto|annual\s+leave|sick\s+leave|off\s+sick|holiday)\b"#
    private static let travelPattern = #"\b(travel|travelling|flight|flying|train|airport|transit)\b"#
    private static let focusPattern = #"\b(focus|admin)\b"#
    private static let holdPattern = #"\b(hold|blocker)\b"#
    private static let oneOnOnePattern = #"\b(1\s*[:\-]\s*1|1[-\s]+(?:to|on)[-\s]+1|one[-\s]+(?:to|on)[-\s]+one)\b"#

    static func categorize(_ context: EventCategorizationContext) -> EventCategory {
        let hasAbsenceMarker = matches(context.title, pattern: absencePattern)

        if hasAbsenceMarker && context.isPersonalEvent {
            return .outOfOffice
        }
        if matches(context.title, pattern: travelPattern) {
            return .travel
        }
        if context.isPersonalEvent && matches(context.title, pattern: focusPattern) {
            return .focusTime
        }
        if matches(context.title, pattern: holdPattern) {
            return .hold
        }
        if matches(context.title, pattern: oneOnOnePattern)
            || (!context.isAllDay && !hasAbsenceMarker && context.otherParticipantCount == 1)
        {
            return .oneOnOne
        }

        guard !context.currentUserDomains.isEmpty,
              !context.participantDomains.isEmpty,
              !context.participantDomains.isDisjoint(with: context.currentUserDomains)
        else {
            return .uncategorized
        }

        if !context.participantDomains.isSubset(of: context.currentUserDomains) {
            return .external
        }
        return .internal
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}