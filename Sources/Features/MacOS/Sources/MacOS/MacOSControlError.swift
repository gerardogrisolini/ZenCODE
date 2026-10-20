import Foundation

enum MacOSControlError: LocalizedError {
    case invalidAction(String, tool: String, allowed: [String])
    case missingArgument(String, String)
    case invalidArgument(String, String)
    case confirmationRequired(String)
    case permissionRequired(String)
    case notFound(String)
    case ambiguous(String)
    case scriptFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAction(action, tool, allowed):
            return "Unsupported action '\(action)' for \(tool). Use one of: \(allowed.joined(separator: ", "))."
        case let .missingArgument(name, action):
            return "Action '\(action)' requires argument '\(name)'."
        case let .invalidArgument(name, reason):
            return "Invalid argument '\(name)': \(reason)"
        case let .confirmationRequired(action):
            return "Action '\(action)' modifies or sends user data and requires confirm=true. Ask the user for explicit approval first, then retry with confirm=true."
        case let .permissionRequired(message):
            return message
        case let .notFound(message):
            return message
        case let .ambiguous(message):
            return message
        case let .scriptFailed(message):
            return message
        case let .operationFailed(message):
            return message
        }
    }
}
