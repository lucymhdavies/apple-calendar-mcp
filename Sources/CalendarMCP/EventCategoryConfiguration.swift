import Foundation

struct EventCategoryConfiguration: Decodable {
    let internalEmailDomains: Set<String>

    enum CodingKeys: String, CodingKey {
        case internalEmailDomains = "internal_email_domains"
    }

    init(internalEmailDomains: Set<String> = []) {
        self.internalEmailDomains = Set(internalEmailDomains.compactMap(Self.normalizeDomain))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let domains = try container.decodeIfPresent([String].self, forKey: .internalEmailDomains) ?? []
        internalEmailDomains = Set(domains.compactMap(Self.normalizeDomain))
    }

    static func load(from url: URL = defaultURL) -> EventCategoryConfiguration {
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(EventCategoryConfiguration.self, from: data)
        else {
            return EventCategoryConfiguration()
        }
        return configuration
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
}