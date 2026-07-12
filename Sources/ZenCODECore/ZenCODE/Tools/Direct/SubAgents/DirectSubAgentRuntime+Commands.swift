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
        parentAllowedToolNames: Set<String>?,
        rootSessionID: String = "default"
    ) async throws -> String {
        let payloads = try Self.requestedAgentPayloads(from: arguments)
        guard !payloads.isEmpty else {
            throw DirectSubAgentRuntimeError.missingArgument("agents")
        }
        guard payloads.count <= Self.maximumAgentsPerCreate else {
            throw DirectSubAgentRuntimeError.agentLimitExceeded(Self.maximumAgentsPerCreate)
        }
        if let taskOrchestrator,
           await taskOrchestrator.executionScope(for: rootSessionID) != nil {
            throw SessionTaskOrchestratorError.permissionDenied(
                "A task-bound delegated sub-agent cannot create nested sub-agents."
            )
        }
        try validateImplementationPayloads(payloads)

        let overviewBatchID = UUID()
        let previousOverviewBatchID = latestOverviewBatchID

        let prepared = payloads.enumerated().map { offset, payload in
            (
                offset: offset,
                payload: payload,
                id: "agent_\(UUID().uuidString.lowercased())",
                profile: profileResolver(payload)
            )
        }
        let claims = prepared.compactMap { item -> TaskClaim? in
            guard let taskID = item.payload.taskID else { return nil }
            return TaskClaim(taskID: taskID, agentID: item.id, executor: .subAgent)
        }

        let claimReceipts: [TaskClaimReceipt]
        if claims.isEmpty {
            claimReceipts = []
        } else {
            guard let taskOrchestrator else {
                throw SessionTaskOrchestratorError.permissionDenied(
                    "Task assignment is unavailable because no session task orchestrator is installed."
                )
            }
            claimReceipts = try await taskOrchestrator.claimTasks(
                sessionID: rootSessionID,
                claims: claims
            )
        }
        let receiptsByAgentID = Dictionary(
            uniqueKeysWithValues: claimReceipts.compactMap { receipt in
                receipt.agentID.map { ($0, receipt) }
            }
        )

        var createdIDs: [String] = []
        var createdBackends: [(String, any AgentRuntimeBackend)] = []
        do {
            for item in prepared {
                let payload = item.payload
                let id = item.id
                let sessionID = "\(id)_session"
                let backendContext = Self.backendContext(
                    for: payload,
                    profile: item.profile
                )
                let backend = try backendFactory(backendContext)
                createdBackends.append((id, backend))
                if let taskOrchestrator {
                    await backend.installTaskOrchestrator(taskOrchestrator)
                }

                let receipt = receiptsByAgentID[id]
                if let receipt, let taskOrchestrator {
                    try await taskOrchestrator.registerExecutionScope(
                        executionSessionID: sessionID,
                        scope: TaskExecutionScope(
                            rootSessionID: rootSessionID,
                            graphID: receipt.graphID,
                            taskID: receipt.taskID,
                            attemptID: receipt.attemptID
                        )
                    )
                }

                var childAllowedToolNames = Self.resolvedAllowedToolNames(
                    requestedToolNames: payload.allowedToolNames,
                    parentAllowedToolNames: parentAllowedToolNames
                )
                if payload.taskID != nil, childAllowedToolNames != nil {
                    childAllowedToolNames?.formUnion(["task.list", "task.get", "task.update"])
                }
                await backend.createSession(
                    id: sessionID,
                    cwd: workingDirectory.path,
                    systemPrompt: Self.systemPrompt(
                        name: payload.name,
                        role: payload.role,
                        isolationMode: payload.isolationMode,
                        taskID: payload.taskID,
                        taskAttemptID: receipt?.attemptID
                    ),
                    history: [],
                    cacheKey: nil,
                    allowedToolNames: childAllowedToolNames,
                    thinkingSelection: backendContext.thinkingSelection,
                    preserveThinking: false
                )

                let now = Date()
                agents[id] = AgentRecord(
                    id: id,
                    sessionID: sessionID,
                    rootSessionID: rootSessionID,
                    taskID: payload.taskID,
                    taskAttemptID: receipt?.attemptID,
                    taskAttemptOrdinal: receipt?.ordinal,
                    name: payload.name.nilIfBlank ?? "sub-agent-\(item.offset + 1)",
                    role: payload.role.nilIfBlank ?? "worker",
                    profileID: item.profile?.id,
                    profileName: item.profile?.name,
                    isolationMode: payload.isolationMode,
                    overviewBatchID: overviewBatchID,
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
        } catch {
            for id in createdIDs {
                agents.removeValue(forKey: id)
            }
            for (id, backend) in createdBackends {
                if let sessionID = prepared.first(where: { $0.id == id }).map({ "\($0.id)_session" }),
                   let taskOrchestrator {
                    await taskOrchestrator.unregisterExecutionScope(
                        executionSessionID: sessionID
                    )
                }
                await backend.shutdown()
            }
            if let taskOrchestrator {
                for receipt in claimReceipts {
                    _ = try? await taskOrchestrator.interruptAttempt(
                        sessionID: rootSessionID,
                        taskID: receipt.taskID,
                        attemptID: receipt.attemptID,
                        reason: "sub-agent batch creation failed: \(error.localizedDescription)"
                    )
                }
            }
            latestOverviewBatchID = previousOverviewBatchID
            throw error
        }

        latestOverviewBatchID = overviewBatchID
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
        try validateImplementationPromptTargets(targetIDs)
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

    @discardableResult
    public func closeAgent(id: String) async -> Bool {
        guard agents[id] != nil else { return false }
        _ = try? await closeAgent(arguments: ["id": .string(id)])
        return agents[id]?.status == .closed
    }

    @discardableResult
    public func closeAgentAssigned(
        to taskID: String,
        rootSessionID: String
    ) async -> Bool {
        guard let agent = agents.values
            .filter({ agent in
                agent.rootSessionID == rootSessionID
                    && agent.taskID == taskID
                    && agent.status.isPending
            })
            .max(by: { $0.createdAt < $1.createdAt }) else {
            return false
        }
        return await closeAgent(id: agent.id)
    }

    @discardableResult
    public func interruptAgents(rootSessionID: String) async -> Int {
        let targetIDs = agents.values
            .filter { $0.rootSessionID == rootSessionID && $0.status != .closed }
            .map(\.id)
        for id in targetIDs {
            guard var agent = agents[id] else { continue }
            let runTask = agent.runTask
            agent.runTask = nil
            agent.pendingPrompts.removeAll()
            agent.status = .closed
            agent.latestError = "Delegated execution interrupted with its root session."
            agent.updatedAt = .now
            agents[id] = agent

            if let taskID = agent.taskID,
               let attemptID = agent.taskAttemptID,
               let taskOrchestrator {
                _ = try? await taskOrchestrator.interruptAttempt(
                    sessionID: rootSessionID,
                    taskID: taskID,
                    attemptID: attemptID,
                    reason: "Root session closed during delegated execution."
                )
                await taskOrchestrator.unregisterExecutionScope(
                    executionSessionID: agent.sessionID
                )
            }
            runTask?.cancel()
            await agent.backend.shutdown()
        }
        return targetIDs.count
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

        if let taskID = agent.taskID,
           let attemptID = agent.taskAttemptID,
           let taskOrchestrator {
            _ = try? await taskOrchestrator.cancelAttempt(
                sessionID: agent.rootSessionID,
                taskID: taskID,
                attemptID: attemptID,
                reason: "Delegated sub-agent closed."
            )
            await taskOrchestrator.unregisterExecutionScope(
                executionSessionID: agent.sessionID
            )
        }
        task?.cancel()
        await agent.backend.shutdown()

        return "Closed delegated sub-agent.\n"
            + Self.renderSnapshots([snapshot(from: agent)], includeLatestOutput: true)
    }
}
