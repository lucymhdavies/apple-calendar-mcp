import Foundation

enum OnePasswordError: Error, LocalizedError {
    case notInstalled
    case notAuthenticated
    case connectionToAppFailed
    case itemNotFound
    case permissionDenied
    case timeoutError
    case parseError(details: String)
    case commandFailed(exitCode: Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "1Password CLI not found. Please install from https://1password.com/downloads/command-line/"
        case .notAuthenticated:
            return "1Password CLI not authenticated. Please enable Developer mode in 1Password settings."
        case .connectionToAppFailed:
            return "Cannot connect to 1Password app. Please open 1Password and try again."
        case .itemNotFound:
            return "Could not find API key in 1Password vault."
        case .permissionDenied:
            return "Permission denied accessing 1Password vault. Please check your vault permissions."
        case .timeoutError:
            return "1Password operation timed out. Please try again."
        case .parseError(let details):
            return "Failed to parse 1Password response: \(details)"
        case .commandFailed(let exitCode):
            return "1Password command failed (exit code: \(exitCode))."
        }
    }
}
