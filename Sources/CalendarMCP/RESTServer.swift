import AppKit
import Darwin
import EventKit
import Foundation
import Network

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

enum RESTPortStore {
    private static let fileName = "rest-port"

    static func write(_ port: UInt16) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CalendarMCP", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(String(port).utf8).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    static func read() -> UInt16? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CalendarMCP", isDirectory: true)
            .appendingPathComponent(fileName)
        guard let value = try? String(contentsOf: path, encoding: .utf8),
            let port = UInt16(value.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0
        else { return nil }
        return port
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

func restJSONEncoder(timeZone: TimeZone = .current) -> JSONEncoder {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .formatted(formatter)
    return encoder
}

private let bonjourServiceName = "CalendarAPI"
private let bonjourServiceType = "_http._tcp"

private struct CalendarsResponse: Encodable {
    let calendars: [CalendarInfo]
}

private struct EventsResponse: Encodable {
    let events: [CalendarEventSummary]
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
    let version: String
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
            let version = Bundle.main.infoDictionary?["CalendarMCPBuildRevision"] as? String ?? "unknown"
            return try encode(HealthResponse(status: "ok", service: "calendar", version: version))
        case "/v1/calendars":
            return try encode(CalendarsResponse(calendars: await service.listCalendars()))
        case "/v1/events":
            if let id = queryValue("id", in: components) {
                return try encode(EventResponse(event: try await service.getEvent(id: id)))
            }
            return try encode(
                EventsResponse(
                    events: try await service.listEventsSummaries(
                        calendarName: queryValue("calendar", in: components),
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
        try restJSONEncoder().encode(value)
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

private final class PermissionRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let completion: @MainActor @Sendable (Bool) -> Void

    init(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func finish(_ granted: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                self.completion(granted)
            }
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var service: CalendarService
    private let backend: CalendarBackend
    private let configuration: RESTConfiguration
    private var server: RESTServer?
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var calendarAccessMenuItem: NSMenuItem!
    private var calendarStatusMenuItem: NSMenuItem!
    private var lanMenuItem: NSMenuItem!
    private var portMenuItem: NSMenuItem!
    private var calendarMenuItem: NSMenuItem!
    private var copyURLMenuItem: NSMenuItem!
    private var lanEnabled = UserDefaults.standard.bool(forKey: lanEnabledDefaultsKey)
    private var configuredPort: UInt16
    private var calendarAccessGranted = false
    private var noCalendarsFound = false

    init(service: CalendarService, backend: CalendarBackend, configuration: RESTConfiguration) {
        self.service = service
        self.backend = backend
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
        Log.message(
            "menu bar: applicationDidFinishLaunching, activationPolicy=\(NSApplication.shared.activationPolicy().rawValue)"
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(running: false)
        let menu = NSMenu()
        statusMenuItem = NSMenuItem(
            title: "Start API", action: #selector(toggleServer), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        calendarAccessMenuItem = NSMenuItem(
            title: "Calendar Access: checking...", action: #selector(requestCalendarAccess), keyEquivalent: "")
        calendarAccessMenuItem.target = self
        menu.addItem(calendarAccessMenuItem)
        calendarStatusMenuItem = NSMenuItem(title: "Serving: checking...", action: nil, keyEquivalent: "")
        calendarStatusMenuItem.target = self
        menu.addItem(calendarStatusMenuItem)
        menu.addItem(.separator())
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
        checkCalendarAccess()
        refreshCalendarStatus()
    }

    @objc private func requestCalendarAccess() {
        Log.message("menu bar: user requested calendar access manually")
        activateForPermissionPrompt()
        calendarAccessMenuItem.title = "Calendar Access: requesting..."
        calendarAccessMenuItem.action = nil
        requestFullAccess { [weak self] granted in
            self?.handleCalendarAccessResult(granted)
        }
    }

    private func handleCalendarAccessResult(_ granted: Bool) {
        calendarAccessGranted = granted
        updateCalendarAccessMenuItem()
        updateStatusIcon(running: server?.isRunning == true)
        guard granted else {
            refreshCalendarStatus()
            return
        }
        // The backend's store may predate this grant and would otherwise keep reporting no
        // calendars; see `CalendarBackend.resetStore`. Hop back via RunLoop (see
        // `checkCalendarAccess` for why not Task/GCD for the MainActor hop).
        Task.detached { [weak self, backend] in
            await backend.resetStore()
            guard let self else { return }
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    self.refreshCalendarStatus()
                }
            }
        }
    }

    /// Brings the app to the foreground before requesting EventKit access. TCC permission
    /// prompts can fail to appear (leaving the request hanging) for accessory/LSUIElement
    /// apps that were launched in the background, e.g. via a LaunchAgent at login.
    private func activateForPermissionPrompt() {
        let policy = NSApplication.shared.activationPolicy()
        Log.message("menu bar: activating app for permission prompt (current activation policy=\(policy.rawValue))")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Checks calendar authorization and requests access if undetermined.
    ///
    /// This deliberately avoids `Task {}`/`DispatchQueue.main.async` to marshal work back to the
    /// main thread: on this build/OS combination the app's main dispatch queue is never
    /// serviced while `NSApplication.run()` is spinning its run loop — a `Task {}` created here,
    /// or a plain `DispatchQueue.main.async` block, silently never executes (confirmed via
    /// instrumentation: neither ever logged). `RunLoop.main.perform` schedules through the
    /// CFRunLoop directly instead of libdispatch's main queue, and that path IS serviced, so
    /// it's used here as the reliable way back onto the main thread.
    private func checkCalendarAccess() {
        Log.message("menu bar: about to call EKEventStore.authorizationStatus(for:)")
        let status = EKEventStore.authorizationStatus(for: .event)
        Log.message("menu bar: startup calendar authorization status=\(status.diagnosticName)")
        calendarAccessGranted = status == .fullAccess
        guard !calendarAccessGranted else {
            updateCalendarAccessMenuItem()
            updateStatusIcon(running: server?.isRunning == true)
            // The backend store may have been created before Calendar access was granted in
            // an earlier launch. Recreate it before serving requests so it observes the
            // current EventKit source state.
            Task.detached { [backend] in
                await backend.resetStore()
            }
            return
        }
        guard status == .notDetermined else {
            updateCalendarAccessMenuItem()
            updateStatusIcon(running: server?.isRunning == true)
            return
        }
        activateForPermissionPrompt()
        calendarAccessMenuItem.title = "Calendar Access: requesting..."
        requestFullAccess { [weak self] granted in
            self?.handleCalendarAccessResult(granted)
        }
    }

    /// Requests EventKit access on a background queue and delivers the result on the main
    /// thread via `RunLoop.main.perform` (see `checkCalendarAccess` for why not GCD/Task).
    private func requestFullAccess(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let gate = PermissionRequestGate(completion: completion)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            Log.message("menu bar: calendar access request timed out")
            gate.finish(false)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Log.message("menu bar: calling requestFullAccessToEvents on background queue")
            let store = EKEventStore()
            let start = Date()
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    Log.message("menu bar: requestFullAccessToEvents error: \(error.localizedDescription)")
                }
                let elapsed = Date().timeIntervalSince(start)
                Log.message(
                    "menu bar: requestFullAccessToEvents resolved granted=\(granted) after \(String(format: "%.1f", elapsed))s, hopping to main thread"
                )
                Log.message("menu bar: delivering calendar access result to UI")
                gate.finish(granted)
            }
        }
    }

    private func updateCalendarAccessMenuItem() {
        if calendarAccessGranted {
            calendarAccessMenuItem.title = "✓ Calendar Access Granted"
            calendarAccessMenuItem.action = nil
        } else {
            calendarAccessMenuItem.title = "⚠ Calendar Access Denied — Click to Request"
            calendarAccessMenuItem.action = #selector(requestCalendarAccess)
        }
    }

    /// Refreshes the "Serving: ..." menu item so calendar problems (no access, no calendars,
    /// or a configured calendar that no longer exists) are visible instead of failing silently.
    private func refreshCalendarStatus() {
        guard calendarAccessGranted else {
            noCalendarsFound = false
            calendarStatusMenuItem.title = "Serving: — (no calendar access)"
            calendarStatusMenuItem.action = nil
            updateStatusIcon(running: server?.isRunning == true)
            return
        }
        let configuredName = service.calendarName
        Task.detached { [weak self, backend, configuredName] in
            let calendars = await backend.listCalendars()
            guard let self else { return }
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    self.applyCalendarStatus(calendars: calendars, configuredName: configuredName)
                }
            }
        }
    }

    @MainActor
    private func applyCalendarStatus(calendars: [CalendarInfo], configuredName: String) {
        if calendars.isEmpty {
            noCalendarsFound = true
            calendarStatusMenuItem.title = "⚠ No Calendars Found — Click to Retry"
            calendarStatusMenuItem.action = #selector(refreshCalendarStatusFromMenu)
        } else if calendars.contains(where: { $0.name == configuredName }) {
            noCalendarsFound = false
            let version = Bundle.main.infoDictionary?["CalendarMCPBuildRevision"] as? String ?? "unknown"
            calendarStatusMenuItem.title = "✓ Serving: \(configuredName) (v\(version))"
            calendarStatusMenuItem.action = nil
        } else {
            noCalendarsFound = true
            calendarStatusMenuItem.title = "⚠ Serving: \"\(configuredName)\" not found — Click to Choose"
            calendarStatusMenuItem.action = #selector(configureCalendar)
        }
        updateStatusIcon(running: server?.isRunning == true)
    }

    @objc private func refreshCalendarStatusFromMenu() {
        refreshCalendarStatus()
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
        let backend = service.backend
        // `service.listCalendars()` only awaits a plain (non-MainActor) actor, so a detached
        // task is safe here; the result is delivered back via RunLoop.perform (see
        // `checkCalendarAccess` for why not Task/GCD for the MainActor hop).
        Task.detached { [weak self, backend] in
            let calendars = await backend.listCalendars()
            guard let self else { return }
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    self.presentCalendarPicker(calendars: calendars)
                }
            }
        }
    }

    @MainActor
    private func presentCalendarPicker(calendars: [CalendarInfo]) {
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
        refreshCalendarStatus()
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

        // Disable the menu item while fetching the key
        lanMenuItem.action = nil
        lanMenuItem.title = "Expose API to LAN (loading...)"
        Log.message("menu: user clicked 'Expose API to LAN', starting 1Password key creation")

        Task {
            do {
                Log.message("menu: calling OnePasswordStore.getOrCreate()")
                _ = try await OnePasswordStore.getOrCreate()
                Log.message("menu: OnePasswordStore.getOrCreate() succeeded")
                
                lanEnabled = true
                UserDefaults.standard.set(true, forKey: lanEnabledDefaultsKey)
                
                // Update UI on main thread
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        Log.message("menu: restarting server for LAN mode")
                        self.restartServer()
                        self.showLANKeyMessage()
                    }
                }
            } catch {
                Log.message("menu: OnePasswordStore.getOrCreate() failed: \(error.localizedDescription)")
                
                // Update UI on main thread with error
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        Log.message("menu: showing error alert to user")
                        self.showError(error.localizedDescription)
                        self.lanMenuItem.action = #selector(self.toggleLAN)
                        self.lanMenuItem.title = "Expose API to LAN"
                    }
                }
            }
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
            // Need to fetch the token from 1Password asynchronously
            lanMenuItem.action = nil
            lanMenuItem.title = "Expose API to LAN (loading...)"

            Task {
                do {
                    let token = try await OnePasswordStore.read()
                    guard let token = token else {
                        throw OnePasswordError.itemNotFound
                    }

                    // Update configuration and start server on main thread
                    RunLoop.main.perform {
                        MainActor.assumeIsolated {
                            let config = self.configuration.binding(
                                host: "0.0.0.0", token: token, port: self.configuredPort)
                            self.startRESTServer(with: config)
                        }
                    }
                } catch {
                    RunLoop.main.perform {
                        MainActor.assumeIsolated {
                            self.showError(error.localizedDescription)
                            self.lanMenuItem.action = #selector(self.toggleLAN)
                            self.lanMenuItem.title = "Expose API to LAN"
                        }
                    }
                }
            }
        } else {
            serverConfiguration = configuration.binding(host: "127.0.0.1", token: nil, port: configuredPort)
            startRESTServer(with: serverConfiguration)
        }
    }

    private func startRESTServer(with config: RESTConfiguration) {
        let server = RESTServer(
            service: service, configuration: config, advertiseBonjour: lanEnabled)
        self.server = server
        updateMenu(running: false)
        server.onStateChange = { [weak self, weak server] running in
            // See `checkCalendarAccess` for why RunLoop.perform is used instead of Task/GCD here.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    guard let self, self.server === server else { return }
                    self.updateMenu(running: running)
                }
            }
        }
        do {
            try server.start()
            RESTPortStore.write(configuredPort)
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

    private func showLANKeyMessage() {
        let alert = NSAlert()
        alert.messageText = "LAN API enabled"
        alert.informativeText =
            "Your API key has been saved in 1Password vault 'Private' with the title 'CalendarMCP REST API Key'.\n\nSearch for this item in 1Password to view or copy the key."
        alert.addButton(withTitle: "Open 1Password")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "onepassword://")!)
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
        if !calendarAccessGranted {
            symbolName = "calendar.badge.exclamationmark"
            description = "Calendar API: no calendar access"
        } else if noCalendarsFound {
            symbolName = "calendar.badge.exclamationmark"
            description = "Calendar API: no calendars available"
        } else if lanEnabled {
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
