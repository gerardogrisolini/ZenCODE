//
//  DirectSubAgentRuntime+AgentControl.swift
//  ZenCODE
//
//  Listing, waiting for, closing, and interrupting delegated agents, plus the
//  task-attempt bookkeeping shared by those commands.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
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
        mutateAgent(
            agentID,
            where: { $0.taskID != nil && $0.status != .closed }
        ) { agent in
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
        }
    }

    func discardInactiveTaskAttemptWork(for agentID: String) {
        finishTaskBoundAttemptWork(
            for: agentID,
            error: "Task attempt is no longer active."
        )
    }

    /// Polls until the targeted agents finish or the timeout elapses.
    ///
    /// When `roomID` is provided, the wait also returns early as soon as the
    /// calling participant's live-chat mailbox holds a message from someone
    /// else. The mailbox is only probed, never drained: the caller's executor
    /// delivers the batch inline in this same tool result. A nil `roomID`
    /// keeps the original completion/timeout-only behaviour.
    public func waitForAgents(
        arguments: [String: JSONValue],
        roomID: String? = nil
    ) async -> String {
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
        let mailboxParticipantID = roomID.map {
            AgentSharedChat.mailboxParticipantID(senderID: sharedChatSenderID, roomID: $0)
        }
        // Watch the mailbox before the first probe below, so a message that
        // arrives between a probe and the wait still wakes it.
        let deliveryObservation = mailboxParticipantID.map {
            observeSharedChatDeliveries(to: $0)
        }
        defer {
            if let deliveryObservation {
                sharedChat.deliverySignal.cancel(deliveryObservation)
            }
        }

        while true {
            // Read together with the state checked below: a change that lands
            // during the mailbox probe makes the wait return at once.
            let wakeGeneration = currentWakeGeneration
            let currentSnapshots = snapshots(for: targetIDs)
            let hasPendingWork = currentSnapshots.contains { $0.pending }
            if !hasPendingWork {
                return Self.renderSnapshots(currentSnapshots, includeLatestOutput: true)
            }
            if Date() >= deadline {
                return "Timed out waiting for delegated sub-agents.\n"
                    + Self.renderSnapshots(currentSnapshots, includeLatestOutput: true)
            }
            if let roomID, let mailboxParticipantID,
               await sharedChat.hasPendingMessages(
                   roomID: roomID,
                   participantID: mailboxParticipantID
               ) {
                // Re-read after the await: agent state may have changed.
                return Self.liveChatMessagesWaitingNotice + "\n"
                    + Self.renderSnapshots(snapshots(for: targetIDs), includeLatestOutput: true)
            }

            do {
                // Polling stays the fallback: a change of an agent's lifecycle
                // or a message for the watched mailbox wakes the wait earlier.
                try await waitForWake(after: wakeGeneration, upTo: .seconds(pollInterval))
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

    static let liveChatMessagesWaitingNotice =
        "Live chat messages are waiting for you; reply with agent.message, then call agent.wait again."

    @discardableResult
    public func closeAgent(id: String) async -> Bool {
        guard agents[id] != nil else { return false }
        do {
            _ = try await closeAgent(arguments: ["id": .string(id)])
            return true
        } catch {
            mutateAgent(id) { agent in
                agent.latestError = "Unable to close delegated task attempt: \(error.localizedDescription)"
                agent.updatedAt = .now
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
            guard let interruption = mutateAgent(id, { agent in
                let isStandby = isStandbyResident(agent)
                let runTask = agent.revokeWorkLoop()
                agent.pendingPrompts.removeAll()
                agent.pendingOperatorReplyFlags.removeAll()
                agent.pendingRelease = false
                agent.pendingReleaseReason = nil
                agent.status = .closed
                agent.latestError = "Delegated execution interrupted with its root session."
                agent.prepareForTerminalRetention()
                agent.updatedAt = .now
                let releasedReservation = takeTasklessDelegationReservation(from: &agent)
                return (
                    agent: agent,
                    isStandby: isStandby,
                    runTask: runTask,
                    releasedReservation: releasedReservation
                )
            }) else {
                continue
            }
            let agent = interruption.agent
            let isStandby = interruption.isStandby
            let runTask = interruption.runTask
            let releasedReservation = interruption.releasedReservation

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
                        // Annotates the current record: a close or prune during the await is kept.
                        mutateAgent(id) { current in
                            current.latestError = "Delegated execution interrupted with its root session.\nUnable to interrupt task attempt: \(error.localizedDescription)"
                            current.updatedAt = .now
                        }
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
        pruneTerminalAgentRecords()
        return targetIDs.count
    }

    public func closeAgent(arguments: [String: JSONValue]) async throws -> String {
        guard let id = try resolveCloseTargetID(arguments: arguments),
              let closing = mutateAgent(id, { agent in
                  let task = agent.revokeWorkLoop()
                  agent.pendingPrompts.removeAll()
                  agent.pendingOperatorReplyFlags.removeAll()
                  agent.pendingRelease = false
                  agent.pendingReleaseReason = nil
                  agent.status = .closed
                  agent.latestError = nil
                  agent.prepareForTerminalRetention()
                  agent.updatedAt = .now
                  let releasedReservation = takeTasklessDelegationReservation(from: &agent)
                  return (agent: agent, task: task, releasedReservation: releasedReservation)
              }) else {
            throw DirectSubAgentRuntimeError.missingArgument("id")
        }
        defer { pruneTerminalAgentRecords() }

        let agent = closing.agent
        let task = closing.task
        let releasedReservation = closing.releasedReservation

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
                // Annotates the current record: a close or prune during the await is kept.
                mutateAgent(id) { current in
                    current.latestError = "Closed delegated sub-agent, but unable to cancel task attempt: \(error.localizedDescription)"
                    current.updatedAt = .now
                }
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
