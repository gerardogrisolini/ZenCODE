//
//  AgentConfigurationError.swift
//  ZenCODE
//
//  Errors reported while parsing and validating the command-line
//  configuration.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import ToolCore

public enum AgentConfigurationError: LocalizedError {
    case conflictingOptions(String, String)
    case invalidValue(String, String)
    case missingValue(String)
    case unknownAgent(String, [String])
    case unknownArgument(String)

    public var errorDescription: String? {
        switch self {
        case let .conflictingOptions(first, second):
            return "Options \(first) and \(second) cannot be combined."
        case let .invalidValue(argument, value):
            return "Invalid value for \(argument): \(value)"
        case let .missingValue(argument):
            return "Missing value for \(argument)."
        case let .unknownAgent(name, availableAgents):
            let available = availableAgents.isEmpty
                ? "No agents are configured in \(AgentProfileStore.agentsManifestURL().path)."
                : "Available agents: \(availableAgents.joined(separator: ", "))."
            return "Unknown agent '\(name)'. \(available)"
        case let .unknownArgument(argument):
            return "Unknown argument: \(argument)"
        }
    }
}
