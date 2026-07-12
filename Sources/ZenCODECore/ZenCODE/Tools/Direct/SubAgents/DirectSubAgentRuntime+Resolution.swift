//
//  DirectSubAgentRuntime+Resolution.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension DirectSubAgentRuntime {
    public func resolveInspectableAgents(arguments: [String: JSONValue]) -> [AgentSnapshot] {
        let identifiers = Self.requestedAgentIdentifiers(from: arguments)
        guard !identifiers.isEmpty else {
            let currentSnapshots = snapshots().filter { $0.status != .closed }
            return currentSnapshots.isEmpty ? snapshots() : currentSnapshots
        }

        return identifiers.compactMap { identifier in
            agentID(matching: identifier).flatMap { agents[$0].map(snapshot(from:)) }
        }
    }

    public func resolveMessageTargetIDs(arguments: [String: JSONValue]) throws -> [String] {
        let identifiers = Self.requestedAgentIdentifiers(from: arguments)
        if !identifiers.isEmpty {
            let ids = identifiers.compactMap(agentID(matching:))
            guard !ids.isEmpty else {
                throw DirectSubAgentRuntimeError.agentNotFound(identifiers.joined(separator: ", "))
            }
            return ids
        }

        let nonClosedAgents = agents.values
            .filter { $0.status != .closed }
            .sorted(by: Self.agentSortOrder)
        let idleAgents = nonClosedAgents.filter { $0.status == .idle }
        if !idleAgents.isEmpty {
            return idleAgents.map(\.id)
        }
        if nonClosedAgents.count == 1,
           let id = nonClosedAgents.first?.id {
            return [id]
        }

        throw DirectSubAgentRuntimeError.missingArgument("id")
    }

    public func resolveWaitTargetIDs(arguments: [String: JSONValue]) -> [String] {
        let identifiers = Self.requestedAgentIdentifiers(from: arguments)
        if !identifiers.isEmpty {
            return identifiers.compactMap(agentID(matching:))
        }

        let pendingIDs = agents.values
            .filter { $0.status.isPending || !$0.pendingPrompts.isEmpty }
            .sorted(by: Self.agentSortOrder)
            .map(\.id)
        if !pendingIDs.isEmpty {
            return pendingIDs
        }

        return agents.values
            .filter { $0.status != .closed }
            .sorted(by: Self.agentSortOrder)
            .map(\.id)
    }

    public func resolveCloseTargetID(arguments: [String: JSONValue]) throws -> String? {
        let identifiers = Self.requestedAgentIdentifiers(from: arguments)
        guard let identifier = identifiers.first else {
            let nonClosedAgents = agents.values.filter { $0.status != .closed }
            return nonClosedAgents.count == 1 ? nonClosedAgents.first?.id : nil
        }
        guard let id = agentID(matching: identifier) else {
            throw DirectSubAgentRuntimeError.agentNotFound(identifier)
        }
        return id
    }

    public func agentID(matching identifier: String) -> String? {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty else {
            return nil
        }
        if agents[normalizedIdentifier] != nil {
            return normalizedIdentifier
        }

        let foldedIdentifier = normalizedIdentifier.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return agents.values
            .sorted(by: Self.agentSortOrder)
            .first { agent in
                agent.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == foldedIdentifier
                    || agent.id.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == foldedIdentifier
                    || agent.taskID?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == foldedIdentifier
            }?
            .id
    }

    public func snapshots() -> [AgentSnapshot] {
        agents.values.sorted(by: Self.agentSortOrder).map(snapshot(from:))
    }

    /// Returns only the most recently created `agent.create` batch for the
    /// transient TUI overview. The full registry remains available through
    /// `snapshots()`, `agent.list`, and the targeted agent commands.
    public func overviewSnapshots() -> [AgentSnapshot] {
        guard let latestOverviewBatchID else {
            return []
        }
        return agents.values
            .filter { $0.overviewBatchID == latestOverviewBatchID }
            .sorted(by: Self.agentSortOrder)
            .map(snapshot(from:))
    }

    public func snapshots(for ids: [String]) -> [AgentSnapshot] {
        ids.compactMap { id in
            agents[id].map(snapshot(from:))
        }
    }

    public func snapshot(from agent: AgentRecord) -> AgentSnapshot {
        AgentSnapshot(
            id: agent.id,
            rootSessionID: agent.rootSessionID,
            taskID: agent.taskID,
            taskAttemptID: agent.taskAttemptID,
            taskAttemptOrdinal: agent.taskAttemptOrdinal,
            name: agent.name,
            role: agent.role,
            profileID: agent.profileID,
            profileName: agent.profileName,
            isolationMode: agent.isolationMode,
            status: agent.status,
            pending: agent.status.isPending || !agent.pendingPrompts.isEmpty,
            modelID: agent.modelID,
            modelRuntime: agent.modelRuntime,
            currentActivity: agent.currentActivity,
            currentToolName: agent.currentToolName,
            latestContentPreview: agent.latestContentPreview,
            latestEventAt: agent.latestEventAt,
            latestOutput: agent.latestOutput,
            accumulatedOutput: agent.accumulatedOutput,
            latestError: agent.latestError,
            createdAt: agent.createdAt,
            updatedAt: agent.updatedAt
        )
    }
}
