//
//  SessionTaskOrchestratorError.swift
//  ZenCODE
//
//  Errors thrown by the session task orchestrator when a task graph operation
//  is invalid, not permitted, or exceeds its limits.
//

import Foundation
import ToolCore

public enum SessionTaskOrchestratorError: LocalizedError, Equatable {
    case invalidSessionID
    case invalidGraphID(String)
    case graphNotFound(String)
    case graphAlreadyExists(String)
    case graphNotMutable(String)
    case graphNotActive(String)
    case invalidTaskID(String)
    case duplicateTaskID(String)
    case taskNotFound(String)
    case emptyTitle(String)
    case dependencyOnSelf(String)
    case missingDependency(taskID: String, dependencyID: String)
    case dependencyCycle([String])
    case graphTooDeep(Int)
    case taskLimitExceeded(Int)
    case valueTooLong(field: String, limit: Int)
    case invalidTransition(taskID: String, from: TaskStatus, to: TaskStatus)
    case taskNotRunnable(String)
    case taskAlreadyClaimed(String)
    case duplicateClaim(String)
    case staleRevision(expected: Int, actual: Int)
    case retryNotAllowed(String)
    case attemptLimitExceeded(String)
    case permissionDenied(String)
    case invalidSnapshot(String)
    case tasklessDelegationRequiresTaskID(String)
    case tasklessDelegationConflict
    case activeGraphBlockedByTasklessDelegation
    case taskRequiresSubAgentExecution(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSessionID:
            return "A non-empty session id is required for task orchestration."
        case let .invalidGraphID(id):
            return "Invalid task graph id '\(id)'."
        case let .graphNotFound(id):
            return "No task graph matched '\(id)'."
        case let .graphAlreadyExists(id):
            return "Task graph '\(id)' already exists."
        case let .graphNotMutable(id):
            return "Task graph '\(id)' is not mutable in its current state."
        case let .graphNotActive(id):
            return "Task graph '\(id)' is not active."
        case let .invalidTaskID(id):
            return "Invalid task id '\(id)'."
        case let .duplicateTaskID(id):
            return "Task id '\(id)' is duplicated."
        case let .taskNotFound(id):
            return "No task matched '\(id)'."
        case let .emptyTitle(id):
            return "Task '\(id)' requires a non-empty title."
        case let .dependencyOnSelf(id):
            return "Task '\(id)' cannot depend on itself."
        case let .missingDependency(taskID, dependencyID):
            return "Task '\(taskID)' depends on missing task '\(dependencyID)'."
        case let .dependencyCycle(path):
            return "Task dependencies contain a cycle: \(path.joined(separator: " -> "))."
        case let .graphTooDeep(limit):
            return "Task graph exceeds the maximum dependency depth of \(limit)."
        case let .taskLimitExceeded(limit):
            return "Task graph exceeds the maximum of \(limit) tasks."
        case let .valueTooLong(field, limit):
            return "Task field '\(field)' exceeds the maximum length of \(limit)."
        case let .invalidTransition(taskID, from, to):
            return "Task '\(taskID)' cannot transition from \(from.rawValue) to \(to.rawValue)."
        case let .taskNotRunnable(id):
            return "Task '\(id)' is not runnable because its graph is inactive or its dependencies are incomplete."
        case let .taskAlreadyClaimed(id):
            return "Task '\(id)' already has an active execution attempt."
        case let .duplicateClaim(id):
            return "Task '\(id)' appears more than once in the claim batch."
        case let .staleRevision(expected, actual):
            return "Task revision is stale (expected \(expected), actual \(actual))."
        case let .retryNotAllowed(id):
            return "Task '\(id)' can only be retried after failure or blocking."
        case let .attemptLimitExceeded(id):
            return "Task '\(id)' reached the retained attempt limit."
        case let .permissionDenied(message):
            return message
        case let .invalidSnapshot(message):
            return "Invalid task graph snapshot: \(message)"
        case let .tasklessDelegationRequiresTaskID(graphID):
            return "Active task graph '\(graphID)' requires every delegated sub-agent to include taskID."
        case .tasklessDelegationConflict:
            return "Coordinated delegation requires a task graph before more than one taskless sub-agent can run."
        case .activeGraphBlockedByTasklessDelegation:
            return "Cannot activate a task graph while a taskless delegated sub-agent is active. Wait for it to finish or close it first."
        case let .taskRequiresSubAgentExecution(taskID):
            return "Task '\(taskID)' belongs to a workflow graph and must be executed by a delegated sub-agent."
        }
    }
}
