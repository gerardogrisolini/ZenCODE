//
//  DirectTodoTaskRuntimeError.swift
//  ZenCODE
//

import Foundation

public enum DirectTodoTaskRuntimeError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String)
    case taskNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown session tool: \(name)"
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .invalidArgument(argument):
            return "Invalid argument: \(argument)"
        case let .taskNotFound(identifier):
            return "No task matched '\(identifier)'."
        }
    }
}

public enum DirectToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case permissionDenied(String)
    case timedOut(String)
    case processFailed(String)
    case invalidResponse(String)
    case toolFailed(String)
    /// Caller supplied an invalid or out-of-range argument value.
    case invalidInput(String)
    /// A named resource (feature, session, graph) was not found.
    case notFound(String)
    /// A persistence or filesystem operation failed.
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown tool: \(name)"
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .permissionDenied(message):
            return message
        case let .timedOut(message),
             let .processFailed(message),
             let .invalidResponse(message),
             let .toolFailed(message),
             let .invalidInput(message),
             let .notFound(message),
             let .persistenceFailed(message):
            return message
        }
    }

    /// A stable, machine-readable category for structured logging and telemetry.
    public var category: String {
        switch self {
        case .unknownTool: return "unknownTool"
        case .missingArgument: return "missingArgument"
        case .permissionDenied: return "permissionDenied"
        case .timedOut: return "timedOut"
        case .processFailed: return "processFailed"
        case .invalidResponse: return "invalidResponse"
        case .toolFailed: return "toolFailed"
        case .invalidInput: return "invalidInput"
        case .notFound: return "notFound"
        case .persistenceFailed: return "persistenceFailed"
        }
    }
}
