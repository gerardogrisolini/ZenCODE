//
//  DirectSubAgentRuntime+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

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
        // Sub-agents created while an earlier batch is still working join that
        // batch, so sequential `agent.create` calls stay visible together in the
        // transient overview instead of replacing each other.
        let overviewBatchID = currentOverviewWaveID()
        let previousOverviewBatchID = latestOverviewBatchID
        let preparePayloads = { () throws -> [(
            offset: Int,
            payload: RequestedAgentPayload,
            id: String,
            profile: AgentProfile
        )] in
            // Capture one authoritative snapshot so every agent in this batch
            // uses the same provider identities through backend creation.
            let catalogSnapshot = self.coordinatesLiveManifestReads
                ? AgentDelegationCatalog.liveSnapshotUnlocked(
                    fileManager: .default
                )
                : self.modelCatalogProvider()
            return try payloads.enumerated().map { offset, payload in
                guard let profileReference = payload.profileReference?.nilIfBlank else {
                    throw DirectSubAgentRuntimeError.missingArgument("profile or agent")
                }
                guard let profile = self.profileResolver(payload) else {
                    throw DirectSubAgentRuntimeError.agentProfileNotFound(profileReference)
                }
                return (
                    offset: offset,
                    payload: try Self.resolvingModelBinding(
                        for: payload,
                        profile: profile,
                        snapshot: catalogSnapshot
                    ),
                    id: "agent_\(UUID().uuidString.lowercased())",
                    profile: profile
                )
            }
        }
        let prepared = if coordinatesLiveManifestReads {
            try SensitiveManifestCoordination.withExclusiveLock(
                operation: preparePayloads
            )
        } else {
            try preparePayloads()
        }
        let reservationIDs = try await reserveTasklessDelegationReservations(
            count: prepared.filter { $0.payload.taskID == nil }.count,
            parentAllowedToolNames: parentAllowedToolNames,
            rootSessionID: rootSessionID
        )
        let tasklessAgentIDs = prepared
            .filter { $0.payload.taskID == nil }
            .map(\.id)
        let reservationIDsByAgentID = Dictionary(
            uniqueKeysWithValues: zip(tasklessAgentIDs, reservationIDs)
        )

        var createdIDs: [String] = []
        var createdBackends: [(String, any AgentRuntimeBackend)] = []
        var claimReceipts: [TaskClaimReceipt] = []
        var advisories: [String] = []
        do {
            let claims = prepared.compactMap { item -> TaskClaim? in
                guard let taskID = item.payload.taskID else { return nil }
                return TaskClaim(taskID: taskID, agentID: item.id, executor: .subAgent)
            }
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
            // Supersede the standby residents whose task was just claimed by a
            // new attempt: a new attempt always wins over an old standby. Only
            // an agent that is actually waiting (`.standby`) is closed right
            // here; a resident whose follow-up is queued or in flight is flagged
            // and released at turn end by `recordStandbyTurnCompletion` /
            // `concludeTaskBoundTurn`, and an `.idle` resident (its follow-up
            // was already denied) stops accepting messages and is reaped. This
            // keeps the post-retry fence observable as a permission error
            // instead of racing the agent to `.closed`.
            for receipt in claimReceipts {
                let supersededResidents = agents.values.filter {
                    isStandbyResident($0)
                        && $0.taskID == receipt.taskID
                        && $0.rootSessionID == rootSessionID
                }
                for record in supersededResidents {
                    agents[record.id]?.supersededByAttemptID = receipt.attemptID
                    agents[record.id]?.pendingRelease = true
                    agents[record.id]?.pendingReleaseReason = Self.standbySupersededReason
                    agents[record.id]?.updatedAt = .now
                    guard record.status == .standby else { continue }
                    await closeStandbyAgent(
                        id: record.id,
                        reason: Self.standbySupersededReason
                    )
                }
            }
            let receiptsByAgentID = Dictionary(
                uniqueKeysWithValues: claimReceipts.compactMap { receipt in
                    receipt.agentID.map { ($0, receipt) }
                }
            )
            _ = try await sharedChat.registerCoordinator(roomID: rootSessionID)
            for item in prepared {
                let payload = item.payload
                let id = item.id
                let sessionID = "\(id)_session"
                let backendContext = Self.backendContext(
                    for: payload,
                    profile: item.profile
                )
                .injecting(
                    sharedChat: sharedChat,
                    sharedChatSenderID: id,
                    sharedChatRoomID: rootSessionID
                )
                let backend = try backendFactory(backendContext)
                let runtime = self
                await backend.updateBorrowedSubAgentToolExecutor { toolCall in
                    try await runtime.executeBorrowedSubAgentTool(
                        senderID: id,
                        rootSessionID: rootSessionID,
                        toolCall: toolCall
                    )
                }
                await synchronizeSubAgentToolEventHandler(with: backend)
                createdBackends.append((id, backend))
                if let taskOrchestrator {
                    await backend.installTaskOrchestrator(taskOrchestrator)
                }

                let receipt = receiptsByAgentID[id]
                if let receipt, let taskOrchestrator {
                    if let capability = payload.capability,
                       let taskView = try? await taskOrchestrator.task(
                           sessionID: rootSessionID,
                           taskID: receipt.taskID,
                           graphID: receipt.graphID
                       ),
                       taskView.task.complexity > capability {
                        let capabilityGap = taskView.task.complexity - capability
                        advisories.append(
                            "Warning: task \"\(receipt.taskID)\" has complexity "
                                + "\(taskView.task.complexity) but agent \"\(payload.name)\" "
                                + "uses profile \"\(item.profile.name)\" with "
                                + "model \"\(payload.modelID ?? "unknown")\" at capability "
                                + "\(capability)/10, a capability gap of "
                                + "\(capabilityGap). Use this profile only when no "
                                + "role-compatible profile with the required tool access has "
                                + "sufficient capability; otherwise select the lowest-capability "
                                + "compatible profile that meets the task complexity."
                        )
                    }
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

                var childAllowedToolNames = item.profile.allowedToolNames()
                if payload.taskID != nil {
                    // Assigned task attempts need these intrinsic reporting tools
                    // even when the selected profile does not coordinate tasks.
                    childAllowedToolNames.formUnion(["tasks.list", "tasks.get", "tasks.update"])
                }
                // Prompt-skill tools are intrinsic and always-on: every
                // delegated sub-agent must be able to discover and read
                // selected prompt-skill guidance, mirroring the top-level
                // session allowlist resolved by AgentCoreAppSessionFactory.
                childAllowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
                childAllowedToolNames = item.profile.resolvedAllowedToolNames(
                    childAllowedToolNames
                )
                // Live collaboration is intrinsic for every delegated agent.
                // list/get are read-only views of the parent's agent graph;
                // message mutates only the transient in-memory mailbox.
                childAllowedToolNames.formUnion([
                    "agent.list", "agent.get", "agent.message"
                ])
                await backend.createSession(
                    id: sessionID,
                    cwd: workingDirectory.path,
                    systemPrompt: Self.systemPrompt(
                        name: payload.name,
                        role: payload.role,
                        taskID: payload.taskID,
                        taskAttemptID: receipt?.attemptID,
                        allowedToolNames: childAllowedToolNames
                    ),
                    history: [],
                    cacheKey: nil,
                    allowedToolNames: childAllowedToolNames,
                    thinkingSelection: backendContext.thinkingSelection,
                    preserveThinking: false
                )
                // Propagate the parent session's prompt-skill provider so the
                // sub-agent can actually execute `skills.list` and `skills.read`
                // through its own backend executor.
                if let promptSkillToolProvider {
                    await backend.updateToolProviders(
                        [promptSkillToolProvider],
                        sessionID: sessionID
                    )
                }

                let now = Date()
                agents[id] = AgentRecord(
                    id: id,
                    sessionID: sessionID,
                    rootSessionID: rootSessionID,
                    taskID: payload.taskID,
                    taskAttemptID: receipt?.attemptID,
                    taskAttemptOrdinal: receipt?.ordinal,
                    tasklessDelegationReservationID: reservationIDsByAgentID[id],
                    name: payload.name.nilIfBlank ?? "sub-agent-\(item.offset + 1)",
                    role: payload.role.nilIfBlank ?? "worker",
                    profileID: item.profile.id,
                    profileName: item.profile.name,
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
                // From this point every following operation can throw. Record
                // the id first so the batch rollback also removes this record,
                // its backend/session scope and its reservation if shared-chat
                // registration rejects it at the participant limit.
                createdIDs.append(id)
                try await registerSharedChatAgent(agents[id]!)

                if let prompt = payload.prompt {
                    try queuePrompt(prompt, for: id)
                }
            }
        } catch {
            for id in createdIDs {
                if let agent = agents[id] {
                    await sharedChat.unregisterParticipant(
                        id: id,
                        roomID: agent.rootSessionID
                    )
                }
                agents.removeValue(forKey: id)
            }
            for (id, backend) in createdBackends {
                if let sessionID = prepared.first(where: { $0.id == id }).map({ "\($0.id)_session" }),
                   let taskOrchestrator {
                    await taskOrchestrator.unregisterExecutionScope(
                        executionSessionID: sessionID
                    )
                }
                await backend.updateBorrowedSubAgentToolExecutor(nil)
                await backend.shutdown()
            }
            if let taskOrchestrator {
                for reservationID in reservationIDs {
                    try? await taskOrchestrator.releaseTasklessDelegationReservation(
                        sessionID: rootSessionID,
                        reservationID: reservationID
                    )
                }
                for receipt in claimReceipts {
                    _ = try await taskOrchestrator.interruptAttempt(
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
        var response = "Created \(snapshots.count) delegated sub-agent\(snapshots.count == 1 ? "" : "s").\n"
            + Self.renderSnapshots(snapshots)
        if !advisories.isEmpty {
            response += "\n" + advisories.joined(separator: "\n")
        }
        return response
    }

    func reserveTasklessDelegationReservations(
        count tasklessCount: Int,
        retainingReservationIDs: Set<UUID> = [],
        parentAllowedToolNames: Set<String>?,
        rootSessionID: String
    ) async throws -> [UUID] {
        guard tasklessCount > 0 || !retainingReservationIDs.isEmpty,
              let taskOrchestrator else {
            return []
        }

        do {
            return try await taskOrchestrator.reserveTasklessDelegations(
                sessionID: rootSessionID,
                count: tasklessCount,
                retainingReservationIDs: retainingReservationIDs,
                requiresExclusiveAccess: SystemPromptBuilder.taskWorkflowToolsAreAvailable(
                    parentAllowedToolNames
                )
            )
        } catch let error as SessionTaskOrchestratorError {
            switch error {
            case let .tasklessDelegationRequiresTaskID(graphID):
                throw DirectSubAgentRuntimeError.taskIDRequiredForActiveTaskGraph(graphID)
            case .tasklessDelegationConflict:
                throw DirectSubAgentRuntimeError.taskGraphRequiredForCoordinatedDelegation
            default:
                throw error
            }
        }
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

    public func messageAgents(
        arguments: [String: JSONValue],
        parentAllowedToolNames: Set<String>? = nil
    ) async throws -> String {
        guard let message = Self.firstString(["message", "prompt", "input"], in: arguments)?.nilIfBlank else {
            throw DirectSubAgentRuntimeError.missingArgument("message")
        }

        let targetIDs = try resolveMessageTargetIDs(arguments: arguments)
        try await validateOpenMessageTargets(targetIDs)
        let tasklessAgents = targetIDs.compactMap { agents[$0] }
            .filter { $0.taskID == nil }
        let tasklessAgentsBySession = Dictionary(
            grouping: tasklessAgents,
            by: \.rootSessionID
        )
        var reservationIDsByAgentID: [String: UUID] = [:]
        do {
            for (rootSessionID, sessionAgents) in tasklessAgentsBySession {
                let retainedReservationIDs = Set(sessionAgents.compactMap(
                    \.tasklessDelegationReservationID
                ))
                let agentsNeedingReservation = sessionAgents.filter {
                    $0.tasklessDelegationReservationID == nil
                }
                let reservationIDs = try await reserveTasklessDelegationReservations(
                    count: agentsNeedingReservation.count,
                    retainingReservationIDs: retainedReservationIDs,
                    parentAllowedToolNames: parentAllowedToolNames,
                    rootSessionID: rootSessionID
                )
                reservationIDsByAgentID.merge(
                    Dictionary(uniqueKeysWithValues: zip(
                        agentsNeedingReservation.map(\.id),
                        reservationIDs
                    )),
                    uniquingKeysWith: { _, latest in latest }
                )
            }
        } catch {
            for (agentID, reservationID) in reservationIDsByAgentID {
                if let rootSessionID = agents[agentID]?.rootSessionID,
                   let taskOrchestrator {
                    try? await taskOrchestrator.releaseTasklessDelegationReservation(
                        sessionID: rootSessionID,
                        reservationID: reservationID
                    )
                }
            }
            throw error
        }

        do {
            try await validateOpenMessageTargets(targetIDs)
            // Resolved before the prompts are queued so the messaged agents join
            // the wave that is on screen right now, instead of the one they
            // themselves are about to make live.
            let overviewWaveID = currentOverviewWaveID()
            for (agentID, reservationID) in reservationIDsByAgentID {
                guard var agent = agents[agentID] else {
                    throw DirectSubAgentRuntimeError.agentNotFound(agentID)
                }
                agent.tasklessDelegationReservationID = reservationID
                agents[agentID] = agent
            }
            for id in targetIDs {
                try queuePrompt(message, for: id)
            }
            adoptOverviewWave(overviewWaveID, for: targetIDs)
        } catch {
            for (agentID, reservationID) in reservationIDsByAgentID {
                if var agent = agents[agentID],
                   agent.tasklessDelegationReservationID == reservationID {
                    agent.tasklessDelegationReservationID = nil
                    agents[agentID] = agent
                }
                if let rootSessionID = agents[agentID]?.rootSessionID,
                   let taskOrchestrator {
                    try? await taskOrchestrator.releaseTasklessDelegationReservation(
                        sessionID: rootSessionID,
                        reservationID: reservationID
                    )
                }
            }
            throw error
        }

        return "Queued message for \(targetIDs.count) delegated sub-agent\(targetIDs.count == 1 ? "" : "s").\n"
            + Self.renderSnapshots(snapshots(for: targetIDs))
    }

    func validateOpenMessageTargets(_ targetIDs: [String]) async throws {
        for agentID in targetIDs {
            guard let agent = agents[agentID] else {
                throw DirectSubAgentRuntimeError.agentNotFound(agentID)
            }
            guard agent.status != .closed else {
                throw DirectSubAgentRuntimeError.agentClosed(agent.name)
            }
            guard await canReceiveMessages(agent) else {
                throw SessionTaskOrchestratorError.permissionDenied(
                    "This delegated sub-agent's task attempt is no longer active "
                        + "and it is not eligible for standby (the graph may be "
                        + "terminal, the task may have been retried, or the standby "
                        + "budget may be exhausted). Use tasks.retry and "
                        + "a canonical agent.create item containing `taskID` to begin a new attempt."
                )
            }
        }
    }

    func hasActiveTaskAttempt(_ agent: AgentRecord) async -> Bool {
        guard agent.taskID != nil else {
            return true
        }
        guard let taskID = agent.taskID,
              let attemptID = agent.taskAttemptID,
              let taskOrchestrator else {
            return false
        }
        guard let scope = await taskOrchestrator.executionScope(for: agent.sessionID),
              scope.rootSessionID == agent.rootSessionID,
              scope.taskID == taskID,
              scope.attemptID == attemptID else {
            return false
        }

        // The attempt id alone is not enough: the scope and assignee must
        // still identify this exact task-bound agent.
        guard let task = try? await taskOrchestrator.task(
            sessionID: agent.rootSessionID,
            taskID: taskID,
            graphID: scope.graphID
        ) else {
            return false
        }
        return task.task.activeAttemptID == attemptID
            && task.task.activeAttempt?.status.isActive == true
            && task.task.activeAttempt?.agentID == agent.id
    }

    func finishTaskBoundAttemptWork(
        for agentID: String,
        error: String?,
        discardingPendingPrompts: Bool = true
    ) {
        guard var agent = agents[agentID],
              agent.taskID != nil,
              agent.status != .closed else {
            return
        }
        if discardingPendingPrompts {
            agent.pendingPrompts.removeAll()
            agent.pendingOperatorReplyFlags.removeAll()
        }
        // `runTask` is deliberately left untouched: the work loop owns it and
        // clears it when it exits. Clearing it here while the loop is still in
        // flight would let a concurrent `queuePrompt` pass the
        // `startAgentIfNeeded` guard and start a second parallel loop.
        agent.status = .idle
        agent.resetActivityState()
        if error != nil {
            agent.latestContentPreview = nil
        }
        agent.latestError = error
        agent.updatedAt = .now
        agents[agentID] = agent
    }

    func discardInactiveTaskAttemptWork(for agentID: String) {
        finishTaskBoundAttemptWork(
            for: agentID,
            error: "Task attempt is no longer active."
        )
    }

    public func waitForAgents(arguments: [String: JSONValue]) async -> String {
        let requestedTimeout = Self.firstNumber(
            ["timeoutSeconds", "timeout_seconds", "timeout"],
            in: arguments
        ) ?? 90
        // Clamp before converting: a finite value such as 1e100 would trap in
        // `Int(_)`, while the bounded value is always representable.
        let timeoutSeconds = Int(min(max(requestedTimeout, 1), 900))
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

            do {
                try await Task.sleep(for: .seconds(pollInterval))
            } catch {
                // Cooperative cancellation: `try?` would swallow the
                // CancellationError and busy-loop on the immediately-returning
                // sleep until the deadline, monopolizing this actor. Stop polling
                // promptly and report the current snapshots.
                return "Cancelled waiting for delegated sub-agents.\n"
                    + Self.renderSnapshots(currentSnapshots, includeLatestOutput: true)
            }
        }
    }

    @discardableResult
    public func closeAgent(id: String) async -> Bool {
        guard agents[id] != nil else { return false }
        do {
            _ = try await closeAgent(arguments: ["id": .string(id)])
            return agents[id]?.status == .closed
        } catch {
            if var agent = agents[id] {
                agent.latestError = "Unable to close delegated task attempt: \(error.localizedDescription)"
                agent.updatedAt = .now
                agents[id] = agent
            }
            return false
        }
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
                    && (agent.status.isPending || agent.status == .standby)
            })
            .max(by: { $0.createdAt < $1.createdAt }) else {
            return false
        }
        return await closeAgent(id: agent.id)
    }

    @discardableResult
    public func interruptAgents(rootSessionID: String) async -> Int {
        // The standby lifecycle is scoped to this root session: stop watching
        // its graph before the agents are torn down so no observer or reaper
        // outlives the session it was started for.
        removeGraphObserver(rootSessionID: rootSessionID)
        let targetIDs = agents.values
            .filter { $0.rootSessionID == rootSessionID && $0.status != .closed }
            .map(\.id)
        for id in targetIDs {
            guard var agent = agents[id] else { continue }
            let isStandby = isStandbyResident(agent)
            let runTask = agent.runTask
            agent.runTask = nil
            agent.pendingPrompts.removeAll()
            agent.pendingOperatorReplyFlags.removeAll()
            agent.pendingRelease = false
            agent.pendingReleaseReason = nil
            agent.status = .closed
            agent.latestError = "Delegated execution interrupted with its root session."
            agent.resetActivityState()
            agent.latestContentPreview = nil
            agent.updatedAt = .now
            let releasedReservation = takeTasklessDelegationReservation(from: &agent)
            agents[id] = agent

            if let taskID = agent.taskID,
               let attemptID = agent.taskAttemptID,
               let taskOrchestrator {
                // A standby resident has no active attempt left to interrupt:
                // its attempt completed before it entered standby.
                if !isStandby {
                    do {
                        _ = try await taskOrchestrator.interruptAttempt(
                            sessionID: rootSessionID,
                            taskID: taskID,
                            attemptID: attemptID,
                            reason: "Root session closed during delegated execution."
                        )
                    } catch {
                        agent.latestError = "Delegated execution interrupted with its root session.\nUnable to interrupt task attempt: \(error.localizedDescription)"
                        agent.updatedAt = .now
                        agents[id] = agent
                    }
                }
                await taskOrchestrator.unregisterExecutionScope(
                    executionSessionID: agent.sessionID
                )
            }
            runTask?.cancel()
            await sharedChat.unregisterParticipant(id: agent.id, roomID: agent.rootSessionID)
            // Same reason as `closeAgent`, once per child session: a delegated
            // turn resolves recall under the sub-agent's own session id, and an
            // interrupted root session must not leave that health state behind.
            await MemoryTurnCoordinator.shared.discard(sessionID: agent.sessionID)
            await agent.backend.updateBorrowedSubAgentToolExecutor(nil)
            await agent.backend.shutdown()
            await releaseTasklessDelegationReservation(releasedReservation)
        }
        stopStandbyReaperIfIdle()
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
        agent.pendingOperatorReplyFlags.removeAll()
        agent.pendingRelease = false
        agent.pendingReleaseReason = nil
        agent.status = .closed
        agent.latestError = nil
        agent.resetActivityState()
        agent.updatedAt = .now
        let releasedReservation = takeTasklessDelegationReservation(from: &agent)
        agents[id] = agent

        var taskCancellationError: (any Error)?
        if let taskID = agent.taskID,
           let attemptID = agent.taskAttemptID,
           let taskOrchestrator {
            do {
                _ = try await taskOrchestrator.cancelAttempt(
                    sessionID: agent.rootSessionID,
                    taskID: taskID,
                    attemptID: attemptID,
                    reason: "Delegated sub-agent closed."
                )
            } catch {
                taskCancellationError = error
                agent.latestError = "Closed delegated sub-agent, but unable to cancel task attempt: \(error.localizedDescription)"
                agent.updatedAt = .now
                agents[id] = agent
            }
            await taskOrchestrator.unregisterExecutionScope(
                executionSessionID: agent.sessionID
            )
        }
        task?.cancel()
        await sharedChat.unregisterParticipant(id: agent.id, roomID: agent.rootSessionID)
        // Delegated turns receive automatic recall, so a closed sub-agent has
        // recall state keyed by its own session id. Drop it here: the runtime
        // recreates sub-agents freely, and a new one must not inherit a paused
        // recall budget from the incarnation it replaces.
        await MemoryTurnCoordinator.shared.discard(sessionID: agent.sessionID)
        await agent.backend.updateBorrowedSubAgentToolExecutor(nil)
        await agent.backend.shutdown()
        await releaseTasklessDelegationReservation(releasedReservation)

        if let taskCancellationError {
            throw taskCancellationError
        }

        return "Closed delegated sub-agent.\n"
            + Self.renderSnapshots([snapshot(from: agent)], includeLatestOutput: true)
    }
}
