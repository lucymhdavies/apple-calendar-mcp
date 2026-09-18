import Foundation
import Network
// NetServiceBrowser/NetService are deprecated in favour of NWBrowser, but NWBrowser
// requires a full TCP connection to resolve a port — which stalls on loopback Bonjour
// services. NetService resolves via DNS-SD SRV records directly and is reliable here.
// The deprecation warning is suppressed below.

private let bonjourServiceName = "CalendarAPI"
private let bonjourServiceType = "_http._tcp"
private let discoveryTimeout: TimeInterval = 5

/// Calls the local REST server as a fallback when EventKit access is unavailable.
/// Discovers the server port via mDNS (Bonjour) so it works regardless of port config.
actor RESTBackend: CalendarDataSource {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Cached after first successful discovery.
    private var cachedBaseURL: URL?

    /// Resolves the Bonjour service once and caches the result for subsequent calls.
    private func baseURL() async throws -> URL {
        if let cached = cachedBaseURL { return cached }
        let port = try await discoverBonjourPort(
            name: bonjourServiceName, timeout: discoveryTimeout)
        let url = URL(string: "http://127.0.0.1:\(port)")!
        cachedBaseURL = url
        return url
    }

    /// Resolves and verifies the REST server is reachable. Call once at startup.
    func checkReachable() async throws {
        let base = try await baseURL()
        let url = base.appendingPathComponent("health")
        let (_, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RESTBackendError.serverUnreachable
        }
        Log.message("REST fallback: connected to \(base)")
    }

    func listCalendars() async -> [CalendarInfo] {
        struct Response: Decodable { let calendars: [CalendarInfo] }
        guard let base = try? await baseURL() else { return [] }
        guard let body: Response = try? await get(base.appendingPathComponent("v1/calendars"))
        else { return [] }
        return body.calendars
    }

    func listEvents(calendarName: String, from: Date, to: Date) async throws -> [CalendarEvent] {
        struct Response: Decodable { let events: [CalendarEvent] }
        let base = try await baseURL()
        var comps = URLComponents(
            url: base.appendingPathComponent("v1/events"), resolvingAgainstBaseURL: false)!
        let fmt = ISO8601DateFormatter()
        comps.queryItems = [
            URLQueryItem(name: "from", value: fmt.string(from: from)),
            URLQueryItem(name: "to", value: fmt.string(from: to)),
        ]
        let body: Response = try await get(comps.url!)
        return body.events
    }

    func getEvent(calendarName: String, id: String) async throws -> CalendarEvent {
        struct Response: Decodable { let event: CalendarEvent }
        let base = try await baseURL()
        var comps = URLComponents(
            url: base.appendingPathComponent("v1/events"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: id)]
        let body: Response = try await get(comps.url!)
        return body.event
    }

    func getFreeBusy(from: Date, to: Date, emails: [String]) async throws -> [FreeBusyResult] {
        struct Response: Decodable { let results: [FreeBusyResult] }
        let base = try await baseURL()
        var comps = URLComponents(
            url: base.appendingPathComponent("v1/freebusy"), resolvingAgainstBaseURL: false)!
        let fmt = ISO8601DateFormatter()
        var items = [
            URLQueryItem(name: "from", value: fmt.string(from: from)),
            URLQueryItem(name: "to", value: fmt.string(from: to)),
        ]
        items += emails.map { URLQueryItem(name: "email", value: $0) }
        comps.queryItems = items
        let body: Response = try await get(comps.url!)
        return body.results
    }

    // MARK: - Private

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RESTBackendError.httpError(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }
}

enum RESTBackendError: LocalizedError {
    case serviceNotFound
    case serverUnreachable
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return
                "CalendarAPI Bonjour service not found. Start CalendarMCP with --rest or via the menu bar app, then retry."
        case .serverUnreachable:
            return
                "Local REST server did not respond. Start CalendarMCP with --rest or via the menu bar app, then retry."
        case .httpError(let code):
            return "REST server returned HTTP \(code)"
        }
    }
}

// MARK: - Bonjour discovery

/// Resolves a Bonjour service to a port using NetService on a dedicated RunLoop thread.
/// Self-retains until finish() fires so the caller needs no strong reference.
/// @unchecked Sendable: all mutations on the dedicated thread's RunLoop.
private final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let serviceName: String
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Int, Error>?
    private var selfRetain: BonjourDiscovery?
    private var browser: NetServiceBrowser?
    private var service: NetService?

    init(serviceName: String, timeout: TimeInterval) {
        self.serviceName = serviceName
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<Int, Error>) {
        self.continuation = continuation
        self.selfRetain = self
        // Run on a dedicated thread so delegate callbacks have a RunLoop.
        Thread.detachNewThread { [self] in self.runLoop() }
    }

    private func runLoop() {
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.schedule(in: .current, forMode: .default)
        browser.searchForServices(ofType: bonjourServiceType, inDomain: "local.")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: timeout + 1))
        if continuation != nil {
            finish(.failure(RESTBackendError.serviceNotFound))
        }
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name == serviceName else { return }
        self.service = service
        service.delegate = self
        service.schedule(in: .current, forMode: .default)
        service.resolve(withTimeout: timeout)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        finish(.failure(RESTBackendError.serviceNotFound))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish(.failure(RESTBackendError.serviceNotFound))
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        finish(.success(sender.port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(.failure(RESTBackendError.serviceNotFound))
    }

    // MARK: -

    private func finish(_ result: Result<Int, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        browser?.stop()
        browser = nil
        service = nil
        selfRetain = nil  // release self-retain
        c.resume(with: result)
    }
}

/// Discovers the named Bonjour service and returns its port.
private func discoverBonjourPort(name: String, timeout: TimeInterval) async throws -> Int {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
        let discovery = BonjourDiscovery(serviceName: name, timeout: timeout)
        discovery.start(continuation)
        // discovery retains itself via selfRetain until finish() fires.
    }
}
