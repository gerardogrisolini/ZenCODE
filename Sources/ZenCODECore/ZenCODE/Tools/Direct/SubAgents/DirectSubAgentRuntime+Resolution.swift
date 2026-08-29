//
//  DirectSubAgentRuntime+Resolution.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension DirectSubAgentRuntime {
    static func boundedTerminalOutput(_ output: String?) -> String? {
        guard let output else { return nil }
        let limit = maximumRetainedTerminalOutputBytes
        guard output.utf8.count > limit else { return output }
        let notice = "[Earlier delegated output discarded to bound memory.]\n"
        let retainedByteCount = max(1, limit - notice.utf8.count)
        let bytes = output.utf8
        var start = bytes.index(
            bytes.endIndex,
            offsetBy: -retainedByteCount
        )
        // Move off a UTF-8 continuation byte so the retained tail starts at a
        // scalar boundary and never needs to keep the original large storage.
        while start < bytes.endIndex,
              (bytes[start] & 0b1100_0000) == 0b1000_0000 {
            start = bytes.index(after: start)
        }
        return notice + String(decoding: bytes[start...], as: UTF8.self)
    }

    /// Keeps only the newest terminal tombstones. Live/idle/standby agents are
    /// never evicted here; their lifecycle remains controlled by normal commands
    /// and the standby reaper.
    func pruneTerminalAgentRecords() {
        let terminal = agents.values
            .filter {
                $0.status == .closed
                    || ($0.status == .failed && $0.taskID != nil)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id > rhs.id
            }
        guard terminal.count > Self.maximumRetainedTerminalAgents else { return }
        for record in terminal.dropFirst(Self.maximumRetainedTerminalAgents) {
            agents.removeValue(forKey: record.id)
        }
    }

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
        // An unaddressed message keeps the established coordinator ergonomics:
        // it targets the live idle agents. Standby agents are only the fallback
        // tier, so a coordinator that still has working agents does not fan an
        // unaddressed follow-up out over every standby budget in the session.
        let idleAgents = nonClosedAgents.filter { $0.status == .idle }
        if !idleAgents.isEmpty {
            return idleAgents.map(\.id)
        }
        let standbyAgents = nonClosedAgents.filter { $0.status == .standby }
        if !standbyAgents.isEmpty {
            return standbyAgents.map(\.id)
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

    /// Returns the sub-agents of the current transient overview wave: the
    /// agents that started working together, plus any agent that still has work
    /// in flight. The full registry remains available through `snapshots()`,
    /// `agent.list`, and the targeted agent commands.
    public func overviewSnapshots() -> [AgentSnapshot] {
        guard let latestOverviewBatchID else {
            return []
        }
        return agents.values
            .filter { $0.overviewBatchID == latestOverviewBatchID || $0.hasWorkInFlight || $0.status == .standby }
            .sorted(by: Self.agentSortOrder)
            .map(snapshot(from:))
    }

    /// Identity that newly started work must adopt to stay visible in the
    /// transient overview.
    ///
    /// `agent.create` and `agent.message` calls issued while an earlier wave is
    /// still working join that wave, so sub-agents started one call at a time
    /// are presented together exactly like a single parallel batch. Work that
    /// starts when nothing is in flight opens a fresh wave, which keeps the
    /// section transient instead of accumulating every agent of the session.
    func currentOverviewWaveID() -> UUID {
        guard let latestOverviewBatchID,
              agents.values.contains(where: {
                  $0.overviewBatchID == latestOverviewBatchID && $0.hasWorkInFlight
              }) else {
            return UUID()
        }
        return latestOverviewBatchID
    }

    /// Re-homes agents that just received new work into `waveID` so the overview
    /// keeps showing every sub-agent that is actually working.
    func adoptOverviewWave(_ waveID: UUID, for agentIDs: [String]) {
        for id in agentIDs {
            agents[id]?.overviewBatchID = waveID
        }
        latestOverviewBatchID = waveID
    }

    public func snapshots(for ids: [String]) -> [AgentSnapshot] {
        ids.compactMap { id in
            agents[id].map(snapshot(from:))
        }
    }

    func snapshot(from agent: AgentRecord) -> AgentSnapshot {
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
            overviewBatchID: agent.overviewBatchID,
            isInCurrentOverviewWave: latestOverviewBatchID.map {
                agent.overviewBatchID == $0
            } ?? false,
            status: agent.status,
            pending: agent.hasWorkInFlight,
            configuredModelID: agent.configuredModelID,
            modelID: agent.modelID,
            currentActivity: agent.currentActivity,
            currentActivityKind: agent.currentActivityKind,
            currentActivityRevision: agent.currentActivityRevision,
            currentToolName: agent.currentToolName,
            currentToolTarget: agent.currentToolTarget,
            latestMetrics: agent.latestMetrics,
            latestContentPreview: agent.latestContentPreview,
            latestEventAt: agent.latestEventAt,
            latestOutput: agent.latestOutput,
            latestOutputRevision: agent.latestOutputRevision,
            accumulatedOutput: agent.accumulatedOutput,
            latestError: agent.latestError,
            createdAt: agent.createdAt,
            updatedAt: agent.updatedAt
        )
    }
}
