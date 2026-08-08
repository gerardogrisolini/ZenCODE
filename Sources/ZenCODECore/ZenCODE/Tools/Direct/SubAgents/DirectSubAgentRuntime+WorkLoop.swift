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

    public func queuePrompt(_ prompt: String, for agentID: String) throws {
        guard var agent = agents[agentID] else {
            throw DirectSubAgentRuntimeError.agentNotFound(agentID)
        }
        guard agent.status != .closed else {
            throw DirectSubAgentRuntimeError.agentClosed(agent.name)
        }

        agent.pendingPrompts.append(prompt)
        agent.latestError = nil
        if agent.status != .running {
            agent.status = .queued
        }
        agent.updatedAt = .now
        agents[agentID] = agent
        startAgentIfNeeded(agentID: agentID)
    }

    public func startAgentIfNeeded(agentID: String) {
        guard var agent = agents[agentID],
              agent.runTask == nil else {
            return
        }

        agent.runTask = Task(name: "Direct sub-agent work loop") {
            await self.runAgentLoop(agentID: agentID)
        }
        agents[agentID] = agent
    }

    /// Releases the work-loop ownership token when the loop exits.
    ///
    /// `runTask` is the single-loop guard read by ``startAgentIfNeeded(agentID:)``.
    /// Only the loop itself may clear it: if any other call site cleared it while
    /// the loop was still in flight, a concurrent ``queuePrompt(_:for:)`` would
    /// pass the guard and start a second parallel loop over the same pending
    /// queue.
    func releaseWorkLoopOwnership(agentID: String) {
        guard var agent = agents[agentID],
              agent.runTask != nil else {
            return
        }
        agent.runTask = nil
        agents[agentID] = agent
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
                // workspace's graph rather than the coordinator's. The main
                // model reads and writes durable memory explicitly through the
                // five `memory.*` tools — there is no automatic extraction and
                // no second LLM call after any turn.
                let memoryBlock: String?
                if let workspaceRootURL = await work.backend
                    .snapshotSession(id: work.sessionID)
                    .map({ URL(fileURLWithPath: $0.workingDirectoryPath) }) {
                    memoryBlock = await MemoryTurnCoordinator.shared.memoryBlock(
                        sessionID: work.sessionID,
                        workspaceRootURL: workspaceRootURL,
                        prompt: work.prompt
                    )
                } else {
                    // No snapshot means no resolvable workspace graph, so the
                    // turn simply runs without a block.
                    memoryBlock = nil
                }
                let response = try await MemoryTurnContext.$currentTurnMemoryBlock
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
        guard var agent = agents[agentID] else {
            return nil
        }
        guard agent.status != .closed else {
            agent.runTask = nil
            agents[agentID] = agent
            return nil
        }
        guard !agent.pendingPrompts.isEmpty else {
            agent.runTask = nil
            if agent.status != .failed && agent.status != .standby {
                agent.status = .idle
            }
            agent.updatedAt = .now
            agents[agentID] = agent
            // Backpressure may have stopped the shared-chat drain while the
            // pending queue was full, and the hold-back stops it entirely while
            // a turn is running. Now that the queue is empty and no turn is in
            // flight, re-arm the drain so messages parked in the bounded
            // mailbox are delivered.
            rearmSharedChatDrain(for: agentID)
            return nil
        }

        let prompt = agent.pendingPrompts.removeFirst()
        agent.status = .running
        agent.currentActivity = nil
        agent.pendingContentBuffer = nil
        agent.currentToolName = nil
        agent.currentToolTarget = nil
        agent.latestContentPreview = nil
        agent.updatedAt = .now
        agents[agentID] = agent

        return AgentWork(
            backend: agent.backend,
            sessionID: agent.sessionID,
            prompt: prompt
        )
    }

    public func recordEvent(
        _ event: DirectAgentEvent,
        agentID: String
    ) {
        guard var agent = agents[agentID],
              agent.status != .closed else {
            return
        }

        switch event {
        case .status, .diagnostic:
            // Backend status and diagnostic events are not model-authored chat
            // updates. Keeping them out of the overview prevents incidental
            // transport chatter from republishing the whole sub-agent section.
            break
        case .thought:
            // Reasoning arrives as a high-frequency delta stream. Its contents
            // are intentionally private here: publish one stable state for the
            // entire thinking phase so signature-based rendering can dedupe all
            // subsequent deltas.
            agent.currentActivity = "🤔 thinking…"
            agent.currentToolName = nil
            agent.currentToolTarget = nil
            agent.latestContentPreview = nil
        case let .modelLoaded(modelID):
            agent.modelID = modelID.nilIfBlank ?? agent.modelID
        case let .content(delta):
            // Assistant content is also streamed as deltas. Buffer it without
            // touching snapshot-visible fields; it becomes visible only when a
            // tool boundary proves that the model's message is complete, or in
            // `recordCompletion` as the final response.
            agent.pendingContentBuffer = (agent.pendingContentBuffer ?? "") + delta
        case let .toolCallStarted(toolCall):
            agent.currentActivity = Self.takeCompletedContent(
                from: &agent.pendingContentBuffer
            )
            agent.currentToolName = toolCall.name
            agent.currentToolTarget = ToolCallPresentation.displayToolTarget(for: toolCall)
            agent.latestContentPreview = nil
        case let .toolCallCompleted(toolCall, _):
            // Retain the compact tool presentation until the next meaningful
            // model state. This makes short tool calls observable on the next
            // periodic refresh without adding a second completion publication.
            agent.currentToolName = toolCall.name
            agent.currentToolTarget = ToolCallPresentation.displayToolTarget(for: toolCall)
        case let .sessionSnapshot(snapshot):
            agent.modelID = snapshot.modelID?.nilIfBlank ?? agent.modelID
        case .metrics,
             .contextWindow,
             .subscriptionUsage,
             .turnEnded:
            break
        }

        agent.latestEventAt = .now
        agent.updatedAt = .now
        agents[agentID] = agent
    }

    private static func takeCompletedContent(
        from buffer: inout String?
    ) -> String? {
        defer { buffer = nil }
        return buffer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
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
            var failedAgent = agent
            failedAgent.latestError = "Unable to mark task attempt running: \(error.localizedDescription)"
            failedAgent.updatedAt = .now
            agents[agentID] = failedAgent
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

    /// Records a completed turn for callers outside the work loop, which always
    /// report a normal tracked attempt turn. The authorization-aware overload
    /// stays internal so ``TurnAuthorization`` is not part of the public surface.
    public func recordCompletion(
        _ response: DirectAgentResponse,
        agentID: String
    ) async {
        await recordCompletion(response, agentID: agentID, authorization: .attempt)
    }

    func recordCompletion(
        _ response: DirectAgentResponse,
        agentID: String,
        authorization: TurnAuthorization
    ) async {
        // The turn is over, so the inline-delivery window closed: anything the
        // drain left in the mailbox has to be re-offered now. Deferred so every
        // exit — standby, task completion, orchestrator failure — re-arms once,
        // and harmless when the loop immediately starts the next queued prompt:
        // the drain simply observes `.running` again and holds back.
        defer { rearmSharedChatDrain(for: agentID) }
        guard var agent = agents[agentID],
              agent.status != .closed else {
            return
        }
        let finalContent = Self.takeCompletedContent(
            from: &agent.pendingContentBuffer
        )
        let trimmedOutput = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.latestOutput = trimmedOutput
        agent.latestOutputRevision &+= 1
        if let existing = agent.accumulatedOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty,
           !trimmedOutput.isEmpty {
            agent.accumulatedOutput = existing + "\n\n" + trimmedOutput
        } else if !trimmedOutput.isEmpty {
            agent.accumulatedOutput = trimmedOutput
        }
        agent.latestError = nil
        agent.modelID = response.modelID.nilIfBlank ?? agent.modelID
        agent.currentActivity = nil
        agent.currentToolName = nil
        agent.currentToolTarget = nil
        // `response.text` may contain commentary from every prior tool round.
        // Preserve it for agent.get/wait, but let the TUI present only the final
        // completed content block when the backend emitted one.
        agent.latestContentPreview = finalContent
        agent.updatedAt = .now
        agents[agentID] = agent

        switch authorization {
        case .standby:
            // Standby turn: do NOT interact with the task orchestrator. The
            // attempt is already completed; this is a conversational follow-up.
            await recordStandbyTurnCompletion(agentID: agentID)
            return

        case .attempt:
            // Normal tracked turn: set status and interact with the orchestrator.
            break

        case .denied:
            // Unreachable: `runAgentLoop` discards the turn and returns before
            // any prompt is sent when the authorization is `.denied`, so no
            // response can ever be recorded for it. Handled as a normal turn
            // only to keep the switch exhaustive without a fatal error.
            break
        }

        // Re-read the agent under a distinct binding: the record was written
        // above and the `.standby` branch may have changed it.
        guard var updatedAgent = agents[agentID] else { return }
        updatedAgent.status = updatedAgent.pendingPrompts.isEmpty ? .idle : .queued
        let releasedReservation = updatedAgent.pendingPrompts.isEmpty
            ? takeTasklessDelegationReservation(from: &updatedAgent)
            : nil
        if releasedReservation != nil {
            // Keep the agent pending until the cross-actor lease release has
            // completed, so graph activation cannot race an apparently idle
            // taskless agent.
            updatedAgent.status = .running
        }
        agents[agentID] = updatedAgent

        if let taskID = updatedAgent.taskID,
           let attemptID = updatedAgent.taskAttemptID,
           let taskOrchestrator {
            do {
                let didComplete = try await taskOrchestrator.completeAttempt(
                    sessionID: updatedAgent.rootSessionID,
                    taskID: taskID,
                    attemptID: attemptID,
                    output: updatedAgent.latestOutput,
                    requiresValidation: false
                )
                if didComplete {
                    await concludeTaskBoundTurn(agentID: agentID)
                } else if let currentAgent = agents[agentID],
                          !(await hasActiveTaskAttempt(currentAgent)) {
                    discardInactiveTaskAttemptWork(for: agentID)
                }
            } catch {
                finishTaskBoundAttemptWork(
                    for: agentID,
                    error: "Unable to complete task attempt: \(error.localizedDescription)"
                )
            }
        }
        await releaseTasklessDelegationReservation(releasedReservation)
    }

    public func recordFailure(
        _ error: Error,
        agentID: String
    ) async {
        guard var agent = agents[agentID] else {
            return
        }
        agent.pendingPrompts.removeAll()
        agent.runTask = nil
        if agent.status != .closed {
            agent.status = .failed
            agent.latestError = error.localizedDescription
            agent.currentActivity = nil
            agent.pendingContentBuffer = nil
            agent.currentToolName = nil
            agent.currentToolTarget = nil
        }
        agent.updatedAt = .now
        let releasedReservation = takeTasklessDelegationReservation(from: &agent)
        agents[agentID] = agent
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
                agent.latestError = "\(agent.latestError ?? "Failed.")\nUnable to fail task attempt: \(error.localizedDescription)"
                agent.updatedAt = .now
                agents[agentID] = agent
            }
        }
        await releaseTasklessDelegationReservation(releasedReservation)
    }

    public func recordCancellation(agentID: String) async {
        guard var agent = agents[agentID] else {
            return
        }
        agent.pendingPrompts.removeAll()
        agent.runTask = nil
        if agent.status != .closed {
            agent.status = .closed
            agent.latestError = "Cancelled."
            agent.currentActivity = nil
            agent.pendingContentBuffer = nil
            agent.currentToolName = nil
            agent.currentToolTarget = nil
        }
        agent.updatedAt = .now
        let releasedReservation = takeTasklessDelegationReservation(from: &agent)
        agents[agentID] = agent
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
                agent.latestError = "\(agent.latestError ?? "Cancelled.")\nUnable to cancel task attempt: \(error.localizedDescription)"
                agent.updatedAt = .now
                agents[agentID] = agent
            }
        }
        await releaseTasklessDelegationReservation(releasedReservation)
    }
}
