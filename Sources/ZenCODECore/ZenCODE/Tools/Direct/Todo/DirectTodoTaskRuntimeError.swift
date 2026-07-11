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

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown tool: \(name)"
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .permissionDenied(message):
            return message
        }
    }
}
