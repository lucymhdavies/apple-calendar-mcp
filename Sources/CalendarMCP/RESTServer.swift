import AppKit
import Foundation
import Network

struct RESTConfiguration {
    let host: String
    let port: UInt16
    let token: String?

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RESTConfiguration {
        let host = environment["REST_HOST"] ?? "127.0.0.1"
        let portValue = environment["REST_PORT"] ?? "8765"
        guard let port = UInt16(portValue), port > 0 else {
            throw RESTServerError.invalidConfiguration("REST_PORT must be between 1 and 65535")
        }
        let token = environment["REST_TOKEN"]
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        guard isLoopback || token.map({ $0.count >= 16 }) == true else {
            throw RESTServerError.invalidConfiguration("REST_TOKEN must be at least 16 characters when REST_HOST is not loopback")
        }
        return RESTConfiguration(host: host, port: port, token: token)
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["REST_ENABLED"]?.lowercased() == "true"
            || ProcessInfo.processInfo.arguments.contains("--rest")
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
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        return data
    }
}

final class RESTServer: @unchecked Sendable {
    let service: CalendarService
    let configuration: RESTConfiguration
    var onStateChange: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "CalendarMCP.RESTServer")
    private var listener: NWListener?
    private(set) var isRunning = false

    init(service: CalendarService, configuration: RESTConfiguration) {
        self.service = service
        self.configuration = configuration
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
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                self?.onStateChange?(true)
                Log.message("REST server listening on \(self?.configuration.host ?? ""):\(self?.configuration.port ?? 0)")
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let requestData = buffer[..<headerEnd.lowerBound]
                Task { [weak self] in
                    let response = await self?.response(for: requestData)
                        ?? HTTPResponse(status: 500, reason: "Internal Server Error", body: Data(), contentType: "text/plain")
                    connection.send(content: response.data(), completion: .contentProcessed { _ in
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
            return HTTPResponse(status: status, reason: "OK", body: body, contentType: "application/json")
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
            return try encode(EventsResponse(events: try await service.listEvents(
                from: queryValue("from", in: components),
                to: queryValue("to", in: components),
                limit: queryValue("limit", in: components).flatMap(Int.init))))
        case "/v1/freebusy":
            let emails = components.queryItems?.filter { $0.name == "email" }.compactMap(\.value) ?? []
            return try encode(FreeBusyResponse(results: try await service.getFreeBusy(
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
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequest(method: String(requestParts[0]), target: String(requestParts[1]), headers: headers)
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
        let reason = status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Internal Server Error"
        return HTTPResponse(status: status, reason: reason, body: data, contentType: "application/json")
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private let service: CalendarService
    private let configuration: RESTConfiguration
    private var server: RESTServer?
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!

    init(service: CalendarService, configuration: RESTConfiguration) {
        self.service = service
        self.configuration = configuration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar API")
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Start API", action: #selector(toggleServer), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)
        let copyItem = NSMenuItem(title: "Copy API URL", action: #selector(copyURL), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        startServer()
    }

    @objc private func toggleServer() {
        if server?.isRunning == true {
            server?.stop()
            updateMenu(running: false)
        } else {
            startServer()
        }
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(configuration.host):\(configuration.port)", forType: .string)
    }

    @objc private func quit() {
        server?.stop()
        NSApplication.shared.terminate(nil)
    }

    private func startServer() {
        let server = RESTServer(service: service, configuration: configuration)
        server.onStateChange = { [weak self] running in
            Task { @MainActor in self?.updateMenu(running: running) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            Log.message("REST server failed to start: \(error.localizedDescription)")
            updateMenu(running: false)
        }
    }

    private func updateMenu(running: Bool) {
        statusMenuItem.title = running ? "Stop API" : "Start API"
        statusItem.button?.image = NSImage(
            systemSymbolName: running ? "calendar.badge.checkmark" : "calendar",
            accessibilityDescription: "Calendar API")
    }
}

private extension CalendarBackendError {
    var isNotFound: Bool {
        switch self {
        case .calendarNotFound, .eventNotFound: return true
        default: return false
        }
    }
}
