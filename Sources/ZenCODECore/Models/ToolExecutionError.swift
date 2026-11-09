//
//  ToolExecutionError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum ToolExecutionError: LocalizedError {
    case toolNotAvailable(String)

    public var errorDescription: String? {
        switch self {
        case let .toolNotAvailable(toolName):
            return "The tool '\(toolName)' is not available in the current assistant mode."
        }
    }
}
