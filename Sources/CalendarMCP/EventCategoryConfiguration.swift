import Foundation

struct EventCategoryConfiguration: Codable {
    let internalEmailDomains: Set<String>
    var eventCategoryOverrides: [String: EventCategory]
    var exceptionHistory: [EventCategoryException]

    enum CodingKeys: String, CodingKey {
        case internalEmailDomains = "internal_email_domains"
        case eventCategoryOverrides = "event_category_overrides"
        case exceptionHistory = "exception_history"
    }

    init(
        internalEmailDomains: Set<String> = [],
        eventCategoryOverrides: [String: EventCategory] = [:],
        exceptionHistory: [EventCategoryException] = []
    ) {
        self.internalEmailDomains = Set(internalEmailDomains.compactMap(Self.normalizeDomain))
        self.eventCategoryOverrides = eventCategoryOverrides.filter { !$0.key.isEmpty }
        self.exceptionHistory = exceptionHistory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let domains = try container.decodeIfPresent([String].self, forKey: .internalEmailDomains) ?? []
        internalEmailDomains = Set(domains.compactMap(Self.normalizeDomain))
        eventCategoryOverrides = try container.decodeIfPresent(
            [String: EventCategory].self, forKey: .eventCategoryOverrides) ?? [:]
        exceptionHistory = try container.decodeIfPresent(
            [EventCategoryException].self, forKey: .exceptionHistory) ?? []
    }

    static func load(from url: URL = defaultURL) -> EventCategoryConfiguration {
        guard let data = try? Data(contentsOf: url),
              let configuration = try? decoder.decode(EventCategoryConfiguration.self, from: data)
        else {
            return EventCategoryConfiguration()
        }
        return configuration
    }

    func categoryOverride(for eventID: String) -> EventCategory? {
        overrideEntry(for: eventID)?.category
    }

    func overrideEntry(for eventID: String) -> (key: String, category: EventCategory)? {
        if let exact = eventCategoryOverrides[eventID] {
            return (eventID, exact)
        }
        guard let occurrence = EventOccurrenceIdentifier.parse(eventID) else { return nil }
        guard let series = eventCategoryOverrides[occurrence.eventIdentifier] else { return nil }
        return (occurrence.eventIdentifier, series)
    }

    mutating func recordOverrideIfNeeded(
        eventID: String, detected: EventCategory, override: EventCategory
    ) -> Bool {
        guard detected != override,
              !exceptionHistory.contains(where: {
                  $0.eventID == eventID && $0.category == override
              })
        else {
            return false
        }
        exceptionHistory.append(
            EventCategoryException(
                eventID: eventID,
                detectedCategory: detected,
                category: override,
                recordedAt: Date(),
                reasonCode: "user_override"))
        return true
    }

    func save(to url: URL = defaultURL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func domain(fromEmailURL url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let value = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let address = String(value.dropFirst(7))
        guard let separator = address.lastIndex(of: "@") else { return nil }
        return normalizeDomain(String(address[address.index(after: separator)...]))
    }

    static func normalizeDomain(_ value: String) -> String? {
        var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasPrefix("@") {
            domain.removeFirst()
        }
        guard !domain.isEmpty,
              domain.contains("."),
              !domain.contains("@"),
              domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              domain.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
              })
        else {
            return nil
        }
        return domain
    }

    private static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CalendarMCP", isDirectory: true)
        .appendingPathComponent("event-categories.json")

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

struct EventCategoryException: Codable, Equatable {
    let eventID: String
    let detectedCategory: EventCategory
    let category: EventCategory
    let recordedAt: Date
    let reasonCode: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case detectedCategory = "detected_category"
        case category
        case recordedAt = "recorded_at"
        case reasonCode = "reason_code"
    }
}