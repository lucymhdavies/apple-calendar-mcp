import Foundation
import Security

enum Log {
    static func message(_ text: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[calendar-api] \(timestamp) \(text)\n".utf8))
    }

    /// Logs process, bundle, and code-signing context once at startup. Helps diagnose
    /// TCC/permission issues that depend on how and by whom the process was launched
    /// (e.g. Terminal/VS Code vs. launchd LaunchAgent vs. another host app).
    static func startupDiagnostics() {
        let info = ProcessInfo.processInfo
        message(
            "process pid=\(info.processIdentifier) ppid=\(getppid()) launchedByLaunchd=\(getppid() == 1)"
        )
        message(
            "bundle id=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundlePath) executable=\(Bundle.main.executablePath ?? "unknown")"
        )
        message("code signing: \(signingSummary())")
    }

    private static func signingSummary() -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return "unavailable (SecCodeCopySelf failed)"
        }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        // SecCodeCopySigningInformation's Swift signature takes SecStaticCode, but it
        // also accepts a SecCode (a dynamic code is a superset of static code info).
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        guard
            SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
            let signingInfo = infoRef as? [String: Any]
        else {
            return "unavailable (SecCodeCopySigningInformation failed)"
        }
        let identifier = signingInfo[kSecCodeInfoIdentifier as String] as? String ?? "unknown"
        let team = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String ?? "none (likely ad-hoc)"
        let cdhash =
            (signingInfo[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }.joined().prefix(16) ?? "unknown"
        return "identifier=\(identifier) team=\(team) cdhash=\(cdhash)…"
    }
}