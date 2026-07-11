//
//  DirectSubAgentRuntimeError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum DirectSubAgentRuntimeError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case agentNotFound(String)
    case agentClosed(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown sub-agent tool: \(name)"
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .agentNotFound(identifier):
            return "No delegated sub-agent matched '\(identifier)'."
        case let .agentClosed(name):
            return "Delegated sub-agent '\(name)' is closed."
        }
    }
}
