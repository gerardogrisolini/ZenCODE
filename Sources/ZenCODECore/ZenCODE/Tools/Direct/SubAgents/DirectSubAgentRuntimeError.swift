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
    case invalidArgument(String)
    case agentNotFound(String)
    case agentClosed(String)
    case agentLimitExceeded(Int)
    case taskGraphRequiredForCoordinatedDelegation
    case taskIDRequiredForActiveTaskGraph(String)
    case agentProfileNotFound(String)
    case modelNotAllowedForProfile(modelID: String, profile: String)
    case modelBindingUnavailable(modelID: String, profile: String, reason: String)
    case ambiguousModelReference(modelID: String, profile: String, candidates: [String])

    public var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown sub-agent tool: \(name)"
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .invalidArgument(argument):
            return "Invalid argument: \(argument)"
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
        case let .agentProfileNotFound(profile):
            return "No configured agent profile matched '\(profile)'."
        case let .modelNotAllowedForProfile(modelID, profile):
            return "Model '\(modelID)' is not an authorized binding for agent profile '\(profile)'."
        case let .modelBindingUnavailable(modelID, profile, reason):
            return "Model binding '\(modelID)' of agent profile '\(profile)' is no longer usable: "
                + "\(reason). Select a binding listed in the delegatable roster or reconfigure the profile."
        case let .ambiguousModelReference(modelID, profile, candidates):
            return "Model reference '\(modelID)' is ambiguous for agent profile '\(profile)' because "
                + "several authorized bindings expose it (\(candidates.joined(separator: ", "))). "
                + "Pass the binding id or the fully qualified model id."
        }
    }
}
