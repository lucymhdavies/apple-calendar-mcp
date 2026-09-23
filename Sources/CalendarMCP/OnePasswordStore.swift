import Foundation

struct OnePasswordStore {
    private static let account = "my.1password.com"
    private static let vault = "Private"
    private static let itemTitle = "CalendarMCP REST API Key"
    private static let itemTag = "lucymhdavies/apple-calendar-mcp"
    private static let opTimeout: TimeInterval = 15
    private static let opPath = "/usr/local/bin/op"

    /// Finds existing API key in 1Password or creates a new one if none exists.
    static func getOrCreate() async throws -> String {
        Log.message("[1password] getOrCreate() called")
        
        // Try to find existing item by tag
        if let existingKey = try await read() {
            Log.message("[1password] Found existing REST API key")
            return existingKey
        }

        // No existing key; create a new one
        Log.message("[1password] Creating new REST API key")
        let key = generateKey()
        try await create(key: key)
        Log.message("[1password] Successfully created and stored new key")
        return key
    }

    /// Retrieves the existing API key from 1Password, if it exists.
    static func read() async throws -> String? {
        // First, find the item by tag to get its ID
        let itemID = try await findItemID()
        guard let itemID = itemID else {
            Log.message("[1password] No existing API key item found")
            return nil
        }

        // Retrieve the password field from the item
        let (output, stderr, exitCode) = try await executeOp([
            "item",
            "get",
            itemID,
            "--account", account,
            "--vault", vault,
            "--fields", "label=password",
        ])

        guard exitCode == 0 else {
            throw mapError(exitCode: exitCode, stderr: stderr)
        }

        let key = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OnePasswordError.parseError(details: "password field is empty")
        }

        return key
    }

    /// Deletes the API key item from 1Password.
    static func delete() async throws {
        guard let itemID = try await findItemID() else {
            Log.message("[1password] No item to delete")
            return
        }

        let (_, stderr, exitCode) = try await executeOp([
            "item",
            "delete",
            itemID,
            "--account", account,
        ])

        guard exitCode == 0 else {
            throw mapError(exitCode: exitCode, stderr: stderr)
        }

        Log.message("[1password] Successfully deleted REST API key")
    }

    // MARK: - Private

    /// Finds the item ID by searching for items with the app tag.
    private static func findItemID() async throws -> String? {
        let (output, stderr, exitCode) = try await executeOp([
            "item",
            "list",
            "--account", account,
            "--vault", vault,
            "--tags", itemTag,
            "--format", "json",
        ])

        guard exitCode == 0 else {
            // If the command fails, it might be because 1Password is not available
            throw mapError(exitCode: exitCode, stderr: stderr)
        }

        guard let data = output.data(using: .utf8) else {
            throw OnePasswordError.parseError(details: "Could not encode response")
        }

        struct Item: Decodable {
            let id: String
        }

        do {
            let items = try JSONDecoder().decode([Item].self, from: data)
            return items.first?.id
        } catch {
            throw OnePasswordError.parseError(details: error.localizedDescription)
        }
    }

    /// Creates a new API key item in 1Password.
    private static func create(key: String) async throws {
        let (_, stderr, exitCode) = try await executeOp([
            "item",
            "create",
            "--account", account,
            "--category", "login",
            "--title", itemTitle,
            "--vault", vault,
            "--tags", itemTag,
            "username=api",
            "password=\(key)",
            "--format", "json",
        ])

        guard exitCode == 0 else {
            throw mapError(exitCode: exitCode, stderr: stderr)
        }

        Log.message("[1password] Successfully created REST API key in 1Password")
    }

    /// Generates a random 32-byte URL-safe base64 key (similar to Keychain version).
    private static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Fallback if SecRandomCopyBytes fails (shouldn't happen)
            return UUID().uuidString + UUID().uuidString
        }
        let key = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return key
    }

    /// Executes an `op` CLI command and returns stdout, stderr, and exit code.
    private static func executeOp(_ arguments: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        Log.message("[1password] executing: op \(arguments.joined(separator: " "))")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["op"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            Log.message("[1password] process started, pid=\(process.processIdentifier)")
        } catch {
            Log.message("[1password] failed to start process: \(error.localizedDescription)")
            throw OnePasswordError.notInstalled
        }

        // Wait for process with timeout
        let startTime = Date()
        while process.isRunning {
            if Date().timeIntervalSince(startTime) > opTimeout {
                Log.message("[1password] command timed out after \(opTimeout)s, terminating")
                process.terminate()
                throw OnePasswordError.timeoutError
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        Log.message("[1password] exit code=\(exitCode), stdout=\(stdout.prefix(100)), stderr=\(stderr.prefix(100))")

        return (stdout, stderr, exitCode)
    }

    /// Maps 1Password CLI exit codes and stderr to appropriate OnePasswordError cases.
    private static func mapError(exitCode: Int32, stderr: String) -> OnePasswordError {
        let lowerStderr = stderr.lowercased()

        if exitCode == 127 {
            return .notInstalled
        }

        if lowerStderr.contains("not signed in")
            || lowerStderr.contains("no accounts configured")
            || lowerStderr.contains("authentication required")
        {
            return .notAuthenticated
        }

        if lowerStderr.contains("lostconnectiontoapp")
            || lowerStderr.contains("connection reset")
            || lowerStderr.contains("connection refused")
        {
            return .connectionToAppFailed
        }

        if lowerStderr.contains("item not found")
            || lowerStderr.contains("couldn't find")
        {
            return .itemNotFound
        }

        if lowerStderr.contains("permission denied")
            || lowerStderr.contains("access denied")
            || lowerStderr.contains("forbidden")
        {
            return .permissionDenied
        }

        if lowerStderr.contains("timeout") || exitCode == 124 {
            return .timeoutError
        }

        return .commandFailed(exitCode: Int(exitCode), stderr: stderr)
    }
}
