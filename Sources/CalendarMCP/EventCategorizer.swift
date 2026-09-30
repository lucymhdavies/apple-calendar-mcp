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
    let attendeeDomains: Set<String>
    let currentUserDomains: Set<String>

    var isCurrentUsersEvent: Bool {
        isCurrentUserOrganizer
            || (!hasOrganizer && isCalendarWritable && otherParticipantCount == 0)
    }

    var isPersonalEvent: Bool {
        isCurrentUsersEvent && otherParticipantCount == 0
    }
}

enum EventCategorizer {
    private static let absencePattern = #"\b(ooo|pto|annual\s+leave|sick\s+leave|off\s+sick|holiday)\b"#
    private static let travelPattern = #"\b(travel|travelling|flight|flying|train|airport|transit)\b"#
    private static let focusPattern = #"\b(focus|admin)\b"#
    private static let holdPattern = #"\b(hold|blocker)\b"#
    private static let oneOnOnePattern = #"\b(1\s*[:\-]\s*1|1[-\s]+(?:to|on)[-\s]+1|one[-\s]+(?:to|on)[-\s]+one)\b"#
    private static let groupEventPattern = #"\b(all[-\s]+hands|all[-\s]+teams|ama|q\s*&\s*a|sessions?|talks?|speakers?|kickoffs?|community|workshops?|webinars?|trainings?|town\s*halls?|office\s+hours|farewell|introducing|social\s+hours?)\b"#

    static func categorize(_ context: EventCategorizationContext) -> EventCategory {
        let hasAbsenceMarker = matches(context.title, pattern: absencePattern)

        if hasAbsenceMarker {
            return context.isCurrentUsersEvent ? .outOfOffice : .uncategorized
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
        let hasOneOnOneMarker = matches(context.title, pattern: oneOnOnePattern)
        let canInferOneOnOne = !context.isAllDay
            && !hasAbsenceMarker
            && !matches(context.title, pattern: groupEventPattern)
            && context.otherParticipantCount == 1
        if hasOneOnOneMarker || canInferOneOnOne {
            return .oneOnOne
        }

        guard !context.currentUserDomains.isEmpty,
              !context.attendeeDomains.isEmpty,
              context.attendeeDomains.contains(where: {
                  isCurrentUserDomain($0, currentUserDomains: context.currentUserDomains)
              })
        else {
            return .uncategorized
        }

        if context.attendeeDomains.contains(where: {
            !isCurrentUserDomain($0, currentUserDomains: context.currentUserDomains)
        }) {
            return .external
        }
        return .internal
    }

    private static func isCurrentUserDomain(
        _ domain: String, currentUserDomains: Set<String>
    ) -> Bool {
        currentUserDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}