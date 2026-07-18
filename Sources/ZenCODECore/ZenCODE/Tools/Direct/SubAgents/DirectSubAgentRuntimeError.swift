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
    case agentLimitExceeded(Int)
    case taskGraphRequiredForCoordinatedDelegation
    case taskIDRequiredForActiveTaskGraph(String)
    case explicitModelRequiresProfile(String)
    case modelNotAllowedForProfile(modelID: String, profile: String)

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
        case let .agentLimitExceeded(limit):
            return "A single agent.create request supports at most \(limit) delegated sub-agents."
        case .taskGraphRequiredForCoordinatedDelegation:
            return "Coordinated delegation requires a task graph. Create the workflow with tasks.create, use tasks.list with runnableOnly=true, then pass taskID for every delegated task."
        case let .taskIDRequiredForActiveTaskGraph(graphID):
            return "Active task graph '\(graphID)' requires every delegated sub-agent to include taskID. Call tasks.list with runnableOnly=true and delegate a runnable task."
        case let .explicitModelRequiresProfile(modelID):
            return "Model '\(modelID)' requires a resolved agent profile with an authorized model binding."
        case let .modelNotAllowedForProfile(modelID, profile):
            return "Model '\(modelID)' is not an authorized binding for agent profile '\(profile)'."
        }
    }
}
