//
//  ToolExecutionError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum ToolExecutionError: LocalizedError {
    case noToolExecutorAvailable(String)
    case toolNotAvailable(String)
    case executionContextUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .noToolExecutorAvailable(toolName):
            return "No tool executor is available for '\(toolName)'."
        case let .toolNotAvailable(toolName):
            return "The tool '\(toolName)' is not available in the current assistant mode."
        case let .executionContextUnavailable(toolName):
            return "The execution context for '\(toolName)' is no longer available."
        }
    }
}
