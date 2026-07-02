//
//  DirectSubAgentRuntime+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

extension DirectSubAgentRuntime {
    public func createAgents(
        arguments: [String: JSONValue],
        workingDirectory: URL,
        parentAllowedToolNames: Set<String>?
    ) async throws -> String {
        let payloads = try Self.requestedAgentPayloads(from: arguments)
        var createdIDs: [String] = []

        for (offset, payload) in payloads.enumerated() {
            let id = "agent_\(UUID().uuidString.lowercased())"
            let sessionID = "\(id)_session"
            let profile = profileResolver(payload)
            let backendContext = Self.backendContext(
                for: payload,
                profile: profile
            )
            let backend = try backendFactory(backendContext)
            let now = Date()
            await backend.createSession(
                id: sessionID,
                cwd: workingDirectory.path,
                systemPrompt: Self.systemPrompt(
                    name: payload.name,
                    role: payload.role,
                    isolationMode: payload.isolationMode
                ),
                history: [],
                cacheKey: nil,
                allowedToolNames: Self.resolvedAllowedToolNames(
                    requestedToolNames: payload.allowedToolNames,
                    parentAllowedToolNames: parentAllowedToolNames
                ),
                thinkingSelection: backendContext.thinkingSelection,
                preserveThinking: false
            )

            agents[id] = AgentRecord(
                id: id,
                sessionID: sessionID,
                name: payload.name.nilIfBlank ?? "sub-agent-\(offset + 1)",
                role: payload.role.nilIfBlank ?? "worker",
                isolationMode: payload.isolationMode,
                backend: backend,
                createdAt: now,
                updatedAt: now,
                status: payload.prompt == nil ? .idle : .queued,
                pendingPrompts: [],
                latestOutput: nil,
                latestError: nil,
                modelID: backendContext.modelID,
                runTask: nil
            )
            createdIDs.append(id)

            if let prompt = payload.prompt {
                try queuePrompt(prompt, for: id)
            }
        }

        let snapshots = snapshots(for: createdIDs)
        return "Created \(snapshots.count) delegated sub-agent\(snapshots.count == 1 ? "" : "s").\n"
            + Self.renderSnapshots(snapshots)
    }

    public func listAgents(arguments: [String: JSONValue]) -> String {
        var snapshots = snapshots()
        if let status = Self.firstString(["status"], in: arguments)
            .flatMap({ Status(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) {
            snapshots = snapshots.filter { $0.status == status }
        }
        return Self.renderSnapshots(snapshots)
    }

    public func getAgents(arguments: [String: JSONValue]) -> String {
        let targets = resolveInspectableAgents(arguments: arguments)
        return Self.renderSnapshots(targets, includeLatestOutput: true)
    }

    public func messageAgents(arguments: [String: JSONValue]) throws -> String {
        guard let message = Self.firstString(["message", "prompt", "input"], in: arguments)?.nilIfBlank else {
            throw DirectSubAgentRuntimeError.missingArgument("message")
        }

        let targetIDs = try resolveMessageTargetIDs(arguments: arguments)
        for id in targetIDs {
            try queuePrompt(message, for: id)
        }

        return "Queued message for \(targetIDs.count) delegated sub-agent\(targetIDs.count == 1 ? "" : "s").\n"
            + Self.renderSnapshots(snapshots(for: targetIDs))
    }

    public func waitForAgents(arguments: [String: JSONValue]) async -> String {
        let timeoutSeconds = min(
            max(Int(Self.firstNumber(["timeoutSeconds", "timeout_seconds", "timeout"], in: arguments) ?? 90), 1),
            900
        )
        let pollInterval = min(
            max(Self.firstNumber(["pollIntervalSeconds", "poll_interval_seconds", "pollInterval"], in: arguments) ?? 1, 0.2),
            5
        )
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let targetIDs = resolveWaitTargetIDs(arguments: arguments)
        guard !targetIDs.isEmpty else {
            return "No active delegated sub-agents."
        }

        while true {
            let currentSnapshots = snapshots(for: targetIDs)
            let hasPendingWork = currentSnapshots.contains { $0.pending }
            if !hasPendingWork {
                return Self.renderSnapshots(currentSnapshots, includeLatestOutput: true)
            }
            if Date() >= deadline {
                return "Timed out waiting for delegated sub-agents.\n"
                    + Self.renderSnapshots(currentSnapshots, includeLatestOutput: true)
            }

            try? await Task.sleep(
                nanoseconds: UInt64(pollInterval * 1_000_000_000)
            )
        }
    }

    public func closeAgent(arguments: [String: JSONValue]) async throws -> String {
        guard let id = try resolveCloseTargetID(arguments: arguments),
              var agent = agents[id] else {
            throw DirectSubAgentRuntimeError.missingArgument("id")
        }

        let task = agent.runTask
        agent.runTask = nil
        agent.pendingPrompts.removeAll()
        agent.status = .closed
        agent.latestError = nil
        agent.updatedAt = .now
        agents[id] = agent

        task?.cancel()
        await agent.backend.shutdown()

        return "Closed delegated sub-agent.\n"
            + Self.renderSnapshots([snapshot(from: agent)], includeLatestOutput: true)
    }
}
