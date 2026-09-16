import AppKit
import Darwin
import Foundation
import Network
import Security

struct RESTConfiguration {
    let host: String
    let port: UInt16
    let token: String?

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RESTConfiguration {
        let host = environment["REST_HOST"] ?? "127.0.0.1"
        let portValue = environment["REST_PORT"] ?? "8765"
        let port = try port(from: portValue)
        let token = environment["REST_TOKEN"]
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        guard isLoopback || token.map({ $0.count >= 16 }) == true else {
            throw RESTServerError.invalidConfiguration(
                "REST_TOKEN must be at least 16 characters when REST_HOST is not loopback")
        }
        return RESTConfiguration(host: host, port: port, token: token)
    }

    static func port(from value: String) throws -> UInt16 {
        guard let port = UInt16(value), port > 0 else {
            throw RESTServerError.invalidConfiguration("API port must be between 1 and 65535")
        }
        return port
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["REST_ENABLED"]?.lowercased() == "true"
            || ProcessInfo.processInfo.arguments.contains("--rest")
    }

    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    func binding(host: String, token: String?, port: UInt16? = nil) -> RESTConfiguration {
        RESTConfiguration(host: host, port: port ?? self.port, token: token)
    }
}

enum APIKeyStore {
    private static let service = "com.lucymhdavies.CalendarMCP"
    private static let account = "REST_API_KEY"

    static func getOrCreate() throws -> String {
        if let existing = try read() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw RESTServerError.invalidConfiguration("could not generate REST API key")
        }
        let key = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
        ]
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw RESTServerError.invalidConfiguration("could not store REST API key")
        }
        return key
    }

    private static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RESTServerError.invalidConfiguration("could not read REST API key")
        }
        return String(data: data, encoding: .utf8)
    }
}

enum RESTServerError: LocalizedError {
    case invalidConfiguration(String)
    case malformedRequest
    case unauthorized
    case unsupportedRoute

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .malformedRequest: return "malformed HTTP request"
        case .unauthorized: return "authorization required"
        case .unsupportedRoute: return "route not found"
        }
    }

    private var message: String {
        switch self {
        case .invalidConfiguration(let message): return message
        case .malformedRequest: return "malformed HTTP request"
        case .unauthorized: return "authorization required"
        case .unsupportedRoute: return "route not found"
        }
    }
}

private let bonjourServiceName = "CalendarAPI"
private let bonjourServiceType = "_http._tcp"

private struct CalendarsResponse: Encodable {
    let calendars: [CalendarInfo]
}

private struct EventsResponse: Encodable {
    let events: [CalendarEvent]
}

private struct EventResponse: Encodable {
    let event: CalendarEvent
}

private struct FreeBusyResponse: Encodable {
    let results: [FreeBusyResult]
}

private struct HealthResponse: Encodable {
    let status: String
    let service: String
}

private struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    let body: Data
    let contentType: String

    func data() -> Data {
        let response =
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        return data
    }
}

final class RESTServer: @unchecked Sendable {
    let service: CalendarService
    let configuration: RESTConfiguration
    let advertiseBonjour: Bool
    var onStateChange: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "CalendarMCP.RESTServer")
    private var listener: NWListener?
    private(set) var isRunning = false

    init(service: CalendarService, configuration: RESTConfiguration, advertiseBonjour: Bool = false) {
        self.service = service
        self.configuration = configuration
        self.advertiseBonjour = advertiseBonjour
    }

    func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RESTServerError.invalidConfiguration("invalid REST port")
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.host), port: port)
        let listener = try NWListener(using: parameters, on: .any)
        if advertiseBonjour {
            listener.service = NWListener.Service(
                name: bonjourServiceName, type: bonjourServiceType, domain: nil, txtRecord: nil)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                self?.onStateChange?(true)
                Log.message(
                    "REST server listening on \(self?.configuration.host ?? ""):\(self?.configuration.port ?? 0)"
                )
            case .failed, .cancelled:
                self?.isRunning = false
                self?.onStateChange?(false)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        onStateChange?(false)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let requestData = buffer[..<headerEnd.lowerBound]
                Task { [weak self] in
                    let response =
                        await self?.response(for: requestData)
                        ?? HTTPResponse(
                            status: 500, reason: "Internal Server Error", body: Data(),
                            contentType: "text/plain")
                    connection.send(
                        content: response.data(),
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                }
            } else if !isComplete && error == nil && buffer.count < 65_536 {
                self?.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func response(for data: Data) async -> HTTPResponse {
        do {
            let request = try parseRequest(data)
            guard authorized(request) else { throw RESTServerError.unauthorized }
            let (status, body): (Int, Data)
            do {
                body = try await route(request)
                status = 200
            } catch let error as RESTServerError {
                throw error
            } catch let error as ServerError {
                return jsonResponse(status: 400, value: ["error": error.localizedDescription])
            } catch let error as CalendarBackendError {
                let status = error.isNotFound ? 404 : 400
                return jsonResponse(status: status, value: ["error": error.localizedDescription])
            } catch {
                return jsonResponse(status: 500, value: ["error": error.localizedDescription])
            }
            return HTTPResponse(
                status: status, reason: "OK", body: body, contentType: "application/json")
        } catch let error as RESTServerError {
            let status: Int
            switch error {
            case .unauthorized: status = 401
            case .unsupportedRoute: status = 404
            case .malformedRequest: status = 400
            case .invalidConfiguration: status = 500
            }
            return jsonResponse(status: status, value: ["error": error.localizedDescription])
        } catch {
            return jsonResponse(status: 500, value: ["error": error.localizedDescription])
        }
    }

    private func route(_ request: HTTPRequest) async throws -> Data {
        guard request.method == "GET" else {
            throw RESTServerError.unsupportedRoute
        }
        let components = try urlComponents(for: request.target)
        switch components.path {
        case "/health":
            return try encode(HealthResponse(status: "ok", service: "calendar"))
        case "/v1/calendars":
            return try encode(CalendarsResponse(calendars: await service.listCalendars()))
        case "/v1/events":
            if let id = queryValue("id", in: components) {
                return try encode(EventResponse(event: try await service.getEvent(id: id)))
            }
            return try encode(
                EventsResponse(
                    events: try await service.listEvents(
                        from: queryValue("from", in: components),
                        to: queryValue("to", in: components),
                        limit: queryValue("limit", in: components).flatMap(Int.init))))
        case "/v1/freebusy":
            let emails =
                components.queryItems?.filter { $0.name == "email" }.compactMap(\.value) ?? []
            return try encode(
                FreeBusyResponse(
                    results: try await service.getFreeBusy(
                        from: queryValue("from", in: components),
                        to: queryValue("to", in: components),
                        emails: emails)))
        default:
            throw RESTServerError.unsupportedRoute
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let token = configuration.token else { return true }
        return request.headers["authorization"] == "Bearer \(token)"
            || request.target.split(separator: "?").first == "/health"
    }

    private func parseRequest(_ data: Data) throws -> HTTPRequest {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RESTServerError.malformedRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw RESTServerError.malformedRequest }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3 else { throw RESTServerError.malformedRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw RESTServerError.malformedRequest }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1]
                .trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(
            method: String(requestParts[0]), target: String(requestParts[1]), headers: headers)
    }

    private func urlComponents(for target: String) throws -> URLComponents {
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            throw RESTServerError.malformedRequest
        }
        return components
    }

    private func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func jsonResponse<T: Encodable>(status: Int, value: T) -> HTTPResponse {
        let data = (try? encode(value)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        let reason =
            status == 400
            ? "Bad Request"
            : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Internal Server Error"
        return HTTPResponse(
            status: status, reason: reason, body: data, contentType: "application/json")
    }
}

private let lanEnabledDefaultsKey = "REST_LAN_ENABLED"
private let portDefaultsKey = "REST_PORT"
private let calendarNameDefaultsKey = "CALENDAR_NAME"

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var service: CalendarService
    private let configuration: RESTConfiguration
    private var server: RESTServer?
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var lanMenuItem: NSMenuItem!
    private var portMenuItem: NSMenuItem!
    private var calendarMenuItem: NSMenuItem!
    private var copyURLMenuItem: NSMenuItem!
    private var lanEnabled = UserDefaults.standard.bool(forKey: lanEnabledDefaultsKey)
    private var configuredPort: UInt16

    init(service: CalendarService, configuration: RESTConfiguration) {
        self.service = service
        self.configuration = configuration
        let savedPort = UserDefaults.standard.integer(forKey: portDefaultsKey)
        configuredPort = savedPort > 0 && savedPort <= Int(UInt16.max)
            ? UInt16(savedPort) : configuration.port
        if let savedCalendar = UserDefaults.standard.string(forKey: calendarNameDefaultsKey),
            !savedCalendar.isEmpty
        {
            self.service.calendarName = savedCalendar
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(running: false)
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(
            title: "Start API", action: #selector(toggleServer), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)
        lanMenuItem = NSMenuItem(
            title: "Expose API to LAN", action: #selector(toggleLAN), keyEquivalent: "")
        lanMenuItem.target = self
        menu.addItem(lanMenuItem)
        portMenuItem = NSMenuItem(
            title: "Configure API Port...", action: #selector(configurePort), keyEquivalent: "")
        portMenuItem.target = self
        menu.addItem(portMenuItem)
        calendarMenuItem = NSMenuItem(
            title: "Choose Calendar...", action: #selector(configureCalendar), keyEquivalent: "")
        calendarMenuItem.target = self
        menu.addItem(calendarMenuItem)
        copyURLMenuItem = NSMenuItem(
            title: "Copy Local API URL", action: #selector(copyURL), keyEquivalent: "")
        copyURLMenuItem.target = self
        menu.addItem(copyURLMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        startServer()
    }

    @objc private func configurePort() {
        let field = NSTextField(string: String(configuredPort))
        field.frame.size.width = 180
        let alert = NSAlert()
        alert.messageText = "Configure API port"
        alert.informativeText = "Choose a port between 1 and 65535. The API will restart."
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let port = try RESTConfiguration.port(from: field.stringValue)
            configuredPort = port
            UserDefaults.standard.set(Int(port), forKey: portDefaultsKey)
            restartServer()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func configureCalendar() {
        Task { @MainActor in
            let calendars = await service.backend.listCalendars()
            guard !calendars.isEmpty else {
                showError("No calendars are available in Calendar.app.")
                return
            }

            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            picker.addItems(withTitles: calendars.map(\.name))
            if let index = calendars.firstIndex(where: { $0.name == service.calendarName }) {
                picker.selectItem(at: index)
            }
            picker.sizeToFit()

            let alert = NSAlert()
            alert.messageText = "Choose calendar"
            alert.informativeText = "Select the calendar used by the API. The API will restart."
            alert.accessoryView = picker
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,
                let selectedName = picker.selectedItem?.title
            else { return }

            service.calendarName = selectedName
            UserDefaults.standard.set(selectedName, forKey: calendarNameDefaultsKey)
            restartServer()
        }
    }

    @objc private func toggleServer() {
        if server?.isRunning == true {
            server?.stop()
            updateMenu(running: false)
        } else {
            startServer()
        }
    }

    @objc private func toggleLAN() {
        if lanEnabled {
            lanEnabled = false
            UserDefaults.standard.set(false, forKey: lanEnabledDefaultsKey)
            restartServer()
            return
        }

        do {
            let key = try APIKeyStore.getOrCreate()
            lanEnabled = true
            UserDefaults.standard.set(true, forKey: lanEnabledDefaultsKey)
            restartServer()
            showLANKey(key)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        let host = lanEnabled ? localIPAddress() : "127.0.0.1"
        NSPasteboard.general.setString("http://\(host):\(configuredPort)", forType: .string)
    }

    @objc private func quit() {
        server?.stop()
        NSApplication.shared.terminate(nil)
    }

    private func startServer() {
        let serverConfiguration: RESTConfiguration
        if lanEnabled {
            do {
                serverConfiguration = configuration.binding(
                    host: "0.0.0.0", token: try APIKeyStore.getOrCreate(), port: configuredPort)
            } catch {
                showError(error.localizedDescription)
                return
            }
        } else {
            serverConfiguration = configuration.binding(host: "127.0.0.1", token: nil, port: configuredPort)
        }
        let server = RESTServer(
            service: service, configuration: serverConfiguration, advertiseBonjour: lanEnabled)
        self.server = server
        updateMenu(running: false)
        server.onStateChange = { [weak self, weak server] running in
            Task { @MainActor in
                guard let self, self.server === server else { return }
                self.updateMenu(running: running)
            }
        }
        do {
            try server.start()
            updateMenu(running: true)
        } catch {
            self.server = nil
            Log.message("REST server failed to start: \(error.localizedDescription)")
            updateMenu(running: false)
        }
    }

    private func restartServer() {
        server?.stop()
        server = nil
        updateMenu(running: false)
        startServer()
    }

    private func showLANKey(_ key: String) {
        let alert = NSAlert()
        alert.messageText = "LAN API key generated"
        alert.informativeText =
            "Copy this key now. Requests from other devices must use it as a Bearer token."
        alert.accessoryView = NSTextField(labelWithString: key)
        alert.addButton(withTitle: "Copy Key")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Calendar API"
        alert.informativeText = message
        alert.runModal()
    }

    private func localIPAddress() -> String {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                let socketAddress = interface.pointee.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                socketAddress, socklen_t(socketAddress.pointee.sa_len), &host,
                socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(decoding: host.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
            break
        }
        return address ?? "127.0.0.1"
    }

    private func updateMenu(running: Bool) {
        statusMenuItem.title = running ? "Stop API" : "Start API"
        lanMenuItem.title = lanEnabled ? "Disable LAN API" : "Expose API to LAN"
        calendarMenuItem.title = "Calendar: \(service.calendarName)"
        copyURLMenuItem.title = lanEnabled ? "Copy LAN API URL" : "Copy Local API URL"
        updateStatusIcon(running: running)
    }

    private func updateStatusIcon(running: Bool) {
        let symbolName: String
        let description: String
        if lanEnabled {
            symbolName = running ? "network" : "network.slash"
            description = running ? "Calendar API exposed to LAN" : "Calendar LAN API stopped"
        } else {
            symbolName = running ? "calendar.badge.checkmark" : "calendar"
            description = running ? "Local Calendar API" : "Local Calendar API stopped"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: description)
    }
}

extension CalendarBackendError {
    fileprivate var isNotFound: Bool {
        switch self {
        case .calendarNotFound, .eventNotFound: return true
        default: return false
        }
    }
}
