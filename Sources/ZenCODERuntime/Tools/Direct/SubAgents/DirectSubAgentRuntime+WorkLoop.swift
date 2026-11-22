//
//  DirectSubAgentRuntime+WorkLoop.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    /// The authorization level for an upcoming agent turn.
    enum TurnAuthorization: Sendable {
        /// The agent has an active task attempt: normal tracked turn.
        case attempt
        /// The agent's attempt is completed but it is standby-eligible:
        /// conversational turn that does NOT mutate the task graph.
        case standby
        /// The agent is neither active nor standby-eligible: stale message.
        case denied
    }

    public func queuePrompt(
        _ prompt: String,
        for agentID: String,
        repliesToOperator: Bool = false
    ) throws {
        guard let agent = agents[agentID] else {
            throw DirectSubAgentRuntimeError.agentNotFound(agentID)
        }
        guard agent.status != .closed else {
            throw DirectSubAgentRuntimeError.agentClosed(agent.name)
        }

        mutateAgent(agentID) { agent in
            agent.pendingPrompts.append(prompt)
            agent.pendingOperatorReplyFlags.append(repliesToOperator)
            agent.latestError = nil
            if agent.status != .running {
                agent.status = .queued
            }
            agent.updatedAt = .now
        }
        startAgentIfNeeded(agentID: agentID)
    }

    public func startAgentIfNeeded(agentID: String) {
        guard let agent = agents[agentID],
              agent.runTask == nil else {
            return
        }

        claimWorkLoop(
            agentID: agentID,
            runTask: Task(name: "Direct sub-agent work loop") {
                await self.runAgentLoop(agentID: agentID)
            }
        )
    }

    /// Records `runTask` as the agent's work-loop ownership token. Only
    /// ``startAgentIfNeeded(agentID:)`` claims it, and only while no loop
    /// holds it.
    private func claimWorkLoop(agentID: String, runTask: Task<Void, Never>) {
        mutateAgent(agentID) { $0.runTask = runTask }
    }

    /// Releases the work-loop ownership token when the loop exits.
    ///
    /// `runTask` is the single-loop guard read by ``startAgentIfNeeded(agentID:)``.
    /// Only the loop itself may clear it: if any other call site cleared it while
    /// the loop was still in flight, a concurrent ``queuePrompt(_:for:)`` would
    /// pass the guard and start a second parallel loop over the same pending
    /// queue. The loop's own exits release it through
    /// ``AgentRecord/releaseWorkLoop()``; closing an agent revokes it together
    /// with the cancellation of the loop through ``AgentRecord/revokeWorkLoop()``.
    func releaseWorkLoopOwnership(agentID: String) {
        mutateAgent(agentID, where: { $0.runTask != nil }) { $0.releaseWorkLoop() }
    }

    public func runAgentLoop(agentID: String) async {
        // Every exit path releases the ownership token, including the standby,
        // discard, failure and cancellation paths, so the next `queuePrompt`
        // starts exactly one new loop.
        //
        // The same exit paths re-arm the shared-chat drain: no turn of this
        // agent is in flight any more, so messages that the drain deliberately
        // left in the mailbox for inline delivery must now become a queued
        // prompt. `nextWork(for:)` covers the empty-queue exit; this covers
        // every other exit (denied authorization, failure, cancellation).
        defer {
            releaseWorkLoopOwnership(agentID: agentID)
            rearmSharedChatDrain(for: agentID)
        }
        while true {
            guard let work = nextWork(for: agentID) else {
                return
            }

            let authorization = await authorizeTurn(agentID: agentID)
            guard authorization != .denied else {
                // A stale queued message must not revive a finished, failed,
                // or retried task attempt, nor an expired standby agent.
                discardInactiveTaskAttemptWork(for: agentID)
                return
            }
            do {
                // Delegated turns get automatic recall as well. The workspace
                // is read from the agent's own session snapshot, so a sub-agent
                // working in a different directory recalls from that
                // workspace's graph rather than the coordinator's; an organizer
                // profile recalls from the global graph instead, as its memory
                // tools do. The main model reads and writes durable memory
                // explicitly through the `memory.*` tools — there is no automatic
                // extraction and no second LLM call after any turn.
                let memoryBlock: String?
                if let workspaceRootURL = await work.backend
                    .snapshotSession(id: work.sessionID)
                    .map({ URL(fileURLWithPath: $0.workingDirectoryPath) }) {
                    memoryBlock = await MemoryTurnCoordinator.shared.memoryBlock(
                        sessionID: work.sessionID,
                        graphTarget: MemoryGraphTarget.resolved(
                            profileRole: agents[agentID]?.profileRole,
                            workingDirectory: workspaceRootURL
                        ),
                        prompt: work.prompt,
                        // Only the entries the agent's own profile wrote.
                        author: agents[agentID]?.profileName
                    )
                } else {
                    // No snapshot means no resolvable workspace graph, so the
                    // turn simply runs without a block.
                    memoryBlock = nil
                }
                // A delegated turn is not the operator's turn: the Task that
                // runs it inherits task-locals from whoever created the agent,
                // so the per-turn instruction is reset explicitly.
                let response = try await AgentTurnInstructionContext.$currentTurnInstruction
                    .withValue(nil) {
                        try await MemoryTurnContext.$currentTurnMemoryBlock
                            .withValue(memoryBlock) {
                                try await work.backend.sendPrompt(
                                    sessionID: work.sessionID,
                                    prompt: work.prompt,
                                    attachments: [],
                                    onEvent: { event in
                                        await self.recordEvent(event, agentID: agentID)
                                    }
                                )
                            }
                    }
                await recordCompletion(response, agentID: agentID, authorization: authorization)
            } catch is CancellationError {
                await recordCancellation(agentID: agentID)
                return
            } catch {
                await recordFailure(error, agentID: agentID)
                return
            }
        }
    }

    public func nextWork(for agentID: String) -> AgentWork? {
        guard let agent = agents[agentID] else {
            return nil
        }
        guard agent.status != .closed else {
            mutateAgent(agentID) { $0.releaseWorkLoop() }
            return nil
        }
        guard !agent.pendingPrompts.isEmpty else {
            mutateAgent(agentID) { agent in
                agent.releaseWorkLoop()
                if agent.status != .failed && agent.status != .standby {
                    agent.status = .idle
                }
                agent.updatedAt = .now
            }
            // Backpressure may have stopped the shared-chat drain while the
            // pending queue was full, and the hold-back stops it entirely while
            // a turn is running. Now that the queue is empty and no turn is in
            // flight, re-arm the drain so messages parked in the bounded
            // mailbox are delivered.
            rearmSharedChatDrain(for: agentID)
            return nil
        }

        return mutateAgent(agentID) { agent in
            let prompt = agent.pendingPrompts.removeFirst()
            let repliesToOperator = agent.pendingOperatorReplyFlags.isEmpty
                ? false
                : agent.pendingOperatorReplyFlags.removeFirst()
            agent.currentTurnRepliesToOperator = repliesToOperator
            agent.currentTurnSentOperatorMessage = false
            agent.status = .running
            agent.executionRevision &+= 1
            agent.resetActivityState()
            // Keep the previous turn's counters on screen until this turn reports
            // its own, then replace them wholesale.
            agent.shouldReplaceMetricsOnNextUpdate = true
            agent.latestContentPreview = nil
            agent.updatedAt = .now
            return AgentWork(
                backend: agent.backend,
                sessionID: agent.sessionID,
                prompt: prompt
            )
        }
    }

    public func recordTaskAttemptStarted(agentID: String) async -> Bool {
        guard let agent = agents[agentID] else {
            return false
        }
        guard agent.taskID != nil else {
            return true
        }
        guard let taskID = agent.taskID,
              let attemptID = agent.taskAttemptID,
              let taskOrchestrator else {
            return false
        }
        guard await hasActiveTaskAttempt(agent) else {
            return false
        }
        do {
            return try await taskOrchestrator.markAttemptRunning(
                sessionID: agent.rootSessionID,
                taskID: taskID,
                attemptID: attemptID
            )
        } catch {
            // Annotates the current record: a close or prune during the await is kept.
            mutateAgent(agentID, where: { $0.status != .closed }) { current in
                current.latestError = "Unable to mark task attempt running: \(error.localizedDescription)"
                current.updatedAt = .now
            }
            return false
        }
    }

    /// Determines whether an upcoming turn should proceed as a tracked task
    /// attempt, a conversational standby turn, or be denied entirely.
    func authorizeTurn(agentID: String) async -> TurnAuthorization {
        guard let agent = agents[agentID] else {
            return .denied
        }
        // Taskless agents always proceed as normal turns.
        guard agent.taskID != nil else {
            return .attempt
        }
        // If the task attempt is still active, mark it running and proceed.
        if await hasActiveTaskAttempt(agent) {
            return await recordTaskAttemptStarted(agentID: agentID) ? .attempt : .denied
        }
        // Attempt is completed: check if the agent is standby-eligible.
        return await isStandbyEligible(agent) ? .standby : .denied
    }

    public func recordFailure(
        _ error: Error,
        agentID: String
    ) async {
        guard let failure = mutateAgent(agentID, { agent in
            agent.pendingPrompts.removeAll()
            agent.pendingOperatorReplyFlags.removeAll()
            agent.releaseWorkLoop()
            if agent.status != .closed {
                agent.status = .failed
                agent.latestError = error.localizedDescription
                if agent.taskID == nil {
                    // Taskless conversational agents are intentionally retryable via
                    // `agent.message`; keep their backend session available.
                    agent.resetActivityState()
                } else {
                    agent.prepareForTerminalRetention()
                }
            }
            agent.updatedAt = .now
            let releasedReservation = takeTasklessDelegationReservation(from: &agent)
            return (agent: agent, releasedReservation: releasedReservation)
        }) else {
            return
        }
        let agent = failure.agent
        let releasedReservation = failure.releasedReservation
        if let taskID = agent.taskID,
           let attemptID = agent.taskAttemptID,
           let taskOrchestrator {
            do {
                _ = try await taskOrchestrator.failAttempt(
                    sessionID: agent.rootSessionID,
                    taskID: taskID,
                    attemptID: attemptID,
                    error: error.localizedDescription,
                    output: agent.latestOutput
                )
            } catch {
                // Annotates the current record: a close or prune during the await is kept.
                mutateAgent(agentID) { current in
                    current.latestError = "\(current.latestError ?? "Failed.")\nUnable to fail task attempt: \(error.localizedDescription)"
                    current.updatedAt = .now
                }
            }
            await taskOrchestrator.unregisterExecutionScope(
                executionSessionID: agent.sessionID
            )
        }
        await releaseTasklessDelegationReservation(releasedReservation)
        if agent.taskID != nil {
            // A failed task attempt cannot be resumed on this agent. Release its
            // heavyweight runtime while retaining a bounded inspection record.
            await sharedChat.unregisterParticipant(id: agent.id, roomID: agent.rootSessionID)
            await MemoryTurnCoordinator.shared.discard(sessionID: agent.sessionID)
            await agent.backend.updateBorrowedSubAgentToolExecutor(nil)
            await agent.backend.shutdown()
            pruneTerminalAgentRecords()
        }
    }

    public func recordCancellation(agentID: String) async {
        guard let cancellation = mutateAgent(agentID, { agent in
            agent.pendingPrompts.removeAll()
            agent.pendingOperatorReplyFlags.removeAll()
            agent.releaseWorkLoop()
            if agent.status != .closed {
                agent.status = .closed
                agent.latestError = "Cancelled."
                agent.prepareForTerminalRetention()
            }
            agent.updatedAt = .now
            let releasedReservation = takeTasklessDelegationReservation(from: &agent)
            return (agent: agent, releasedReservation: releasedReservation)
        }) else {
            return
        }
        let agent = cancellation.agent
        let releasedReservation = cancellation.releasedReservation
        if let taskID = agent.taskID,
           let attemptID = agent.taskAttemptID,
           let taskOrchestrator {
            do {
                _ = try await taskOrchestrator.cancelAttempt(
                    sessionID: agent.rootSessionID,
                    taskID: taskID,
                    attemptID: attemptID,
                    reason: "Delegated sub-agent cancelled."
                )
            } catch {
                // Annotates the current record: a close or prune during the await is kept.
                mutateAgent(agentID) { current in
                    current.latestError = "\(current.latestError ?? "Cancelled.")\nUnable to cancel task attempt: \(error.localizedDescription)"
                    current.updatedAt = .now
                }
            }
            await taskOrchestrator.unregisterExecutionScope(
                executionSessionID: agent.sessionID
            )
        }
        await releaseTasklessDelegationReservation(releasedReservation)
        await sharedChat.unregisterParticipant(id: agent.id, roomID: agent.rootSessionID)
        await MemoryTurnCoordinator.shared.discard(sessionID: agent.sessionID)
        await agent.backend.updateBorrowedSubAgentToolExecutor(nil)
        await agent.backend.shutdown()
        pruneTerminalAgentRecords()
    }
}
