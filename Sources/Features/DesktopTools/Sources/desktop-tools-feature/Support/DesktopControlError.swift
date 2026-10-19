//  Created by Gerardo Grisolini on 30/05/26.
//
import ApplicationServices
import Foundation

enum DesktopControlError: LocalizedError {
    case invalidAction(String)
    case missingArgument(String, String)
    case invalidArgument(String, String)
    case permissionRequired(String)
    case appNotFound
    case windowNotFound
    case processFailed(String)
    case accessibilityFailed(String, AXError)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAction(action):
            return "Unsupported desktop action: \(action)."
        case let .missingArgument(name, action):
            return "Action '\(action)' requires argument '\(name)'."
        case let .invalidArgument(name, reason):
            return "Invalid argument '\(name)': \(reason)"
        case let .permissionRequired(message):
            return message
        case .appNotFound:
            return "No matching running application was found. Use list_apps, or launch it first."
        case .windowNotFound:
            return "No matching window was found. Use list_windows and prefer window_id for exact selection."
        case let .processFailed(message):
            return message
        case let .accessibilityFailed(operation, error):
            return "Accessibility operation '\(operation)' failed with AXError \(error.rawValue)."
        case let .operationFailed(message):
            return message
        }
    }
}

enum DesktopWindowSelectionPolicy {
    static func selectedProcessID(
        requestedWindowID: UInt32?,
        matchingWindowPID: pid_t?,
        fallbackProcessID: () -> pid_t?
    ) throws -> pid_t {
        if requestedWindowID != nil {
            guard let matchingWindowPID else {
                throw DesktopControlError.windowNotFound
            }
            return matchingWindowPID
        }

        guard let fallbackPID = fallbackProcessID() else {
            throw DesktopControlError.appNotFound
        }
        return fallbackPID
    }
}
