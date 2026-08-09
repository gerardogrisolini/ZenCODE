//
//  DirectSubAgentRuntime+Standby.swift
//  ZenCODE
//
//  Standby lifecycle for task-bound sub-agents. After an agent completes its
//  attempt it enters `.standby` instead of being discarded: it stays alive,
//  remains registered in the shared chat, and can receive and respond to
//  messages from the coordinator or peers until the task graph reaches a
//  terminal state, a newer attempt supersedes it, or the standby budget/timeout
//  is exhausted.
//
//  Standby turns do NOT mutate the task graph — the attempt is already
//  completed and `task.activeAttemptID` is nil for this agent.  Standby is a
//  runtime-only, transient concept: nothing about standby is persisted.
//

import Foundation

extension DirectSubAgentRuntime {
    /// True when the agent may enter or remain in standby.
    ///
    /// Conditions:
    /// - The agent is task-bound (standby does not apply to taskless agents).
    /// - The agent is not closed or failed.
    /// - The graph that authorised standby is still non-terminal.
    /// - The agent's own task is not failed or cancelled.
    /// - The standby turn budget and idle timeout are not exhausted.
    /// - The agent has not been superseded by a newer attempt.
    func isStandbyEligible(_ agent: AgentRecord) async -> Bool {
        guard let taskID = agent.taskID,
              agent.status != .closed,
              agent.status != .failed,
              agent.supersededByAttemptID == nil,
              !agent.pendingRelease,
              let taskOrchestrator else {
            return false
        }
        guard agent.standbyTurns < Self.maximumStandbyTurnsPerAgent else {
            return false
        }
        if let standbySince = agent.standbySince,
           Date().timeIntervalSince(standbySince) > Self.standbyIdleTimeout {
            return false
        }
        // Resolve the graph ID: use the stored standby graph ID, or fall back
        // to the execution scope (needed for the initial standby entry before
        // standbyGraphID has been set).
        let graphID: String?
        if let standbyGraphID = agent.standbyGraphID {
            graphID = standbyGraphID
        } else {
            graphID = await resolveGraphID(for: agent)
        }
        guard let graphID else {
            return false
        }
        guard let snapshot = try? await taskOrchestrator.graphSnapshot(
            sessionID: agent.rootSessionID,
            graphID: graphID
        ) else {
            return false
        }
        guard !snapshot.state.isTerminal else {
            return false
        }
        // Reject standby for tasks that have failed or been cancelled so the
        // validation fence tested by
        // `workflowAttemptIsFencedAfterValidationFailureUntilRetryCreatesANewAgent`
        // is preserved.  A `.completed` task is intentionally allowed: the
        // agent should remain reachable in standby until the task graph itself
        // reaches a terminal state (at which point `releaseStandbyAgents`
        // closes it).
        if let task = snapshot.tasks.first(where: { $0.id == taskID }) {
            if task.status == .failed || task.status == .cancelled {
                return false
            }
            // If the task has a new active attempt owned by a different agent,
            // this agent has been superseded and must not enter standby.
            if let activeAgentID = task.activeAttempt?.agentID,
               activeAgentID != agent.id {
                return false
            }
        }
        return true
    }

    /// Convenience predicate that allows message delivery when the agent has
    /// either an active attempt or is standby-eligible.
    func canReceiveMessages(_ agent: AgentRecord) async -> Bool {
        if await hasActiveTaskAttempt(agent) {
            return true
        }
        return await isStandbyEligible(agent)
    }

    /// True when the record occupies a standby slot: a task-bound agent whose
    /// attempt already completed and that was admitted to standby.
    ///
    /// A standby resident is not necessarily `.standby`: it is `.queued` or
    /// `.running` while it processes a standby follow-up, and `.idle` when a
    /// follow-up was denied (terminal task, retried attempt, exhausted budget).
    /// Every release path uses this predicate so an in-flight standby turn is
    /// never mistaken for a live task attempt.
    func isStandbyResident(_ agent: AgentRecord) -> Bool {
        agent.standbyGraphID != nil && agent.status != .closed
    }

    /// True while any agent still occupies a standby slot. Drives the lifetime
    /// of the periodic reaper.
    var hasStandbyResidents: Bool {
        agents.values.contains { isStandbyResident($0) }
    }

    /// Transitions a task-bound agent into standby after its attempt completed.
    /// The agent stays visible, registered in the shared chat, and ready to
    /// receive new prompts.  Pending prompts are preserved (fix for F9).
    func enterStandby(agentID: String, graphID: String) async {
        guard let candidate = agents[agentID],
              candidate.taskID != nil,
              candidate.status != .closed else {
            return
        }
        await enforceStandbyCapacity(
            rootSessionID: candidate.rootSessionID,
            admitting: agentID
        )
        // Re-read after the capacity await: the record may have been closed
        // while the oldest residents were released.
        guard var agent = agents[agentID],
              agent.taskID != nil,
              agent.status != .closed else {
            return
        }
        agent.status = agent.pendingPrompts.isEmpty ? .standby : .queued
        agent.standbyGraphID = graphID
        agent.standbySince = .now
        agent.updatedAt = .now
        // `latestError` is deliberately preserved: standby is not a success
        // signal and must not mask an error reported by the completed attempt.
        agents[agentID] = agent
        ensureStandbyReaper()
    }

    /// Enforces ``DirectSubAgentRuntime/maximumStandbyAgentsPerRootSession``
    /// before one more agent enters standby, closing the least recently active
    /// standby residents (LRU by `standbySince`) of the same root session.
    /// Ordering is deterministic: `standbySince`, then agent id.
    func enforceStandbyCapacity(
        rootSessionID: String,
        admitting agentID: String
    ) async {
        let capacity = Self.maximumStandbyAgentsPerRootSession
        while true {
            let residents = agents.values
                .filter {
                    isStandbyResident($0)
                        && $0.rootSessionID == rootSessionID
                        && $0.id != agentID
                }
            guard residents.count >= capacity else {
                return
            }
            // Never evict a resident whose follow-up turn is in flight: it is
            // re-evaluated at turn end anyway, and cancelling it mid-response
            // would discard work already paid for. When every resident is busy
            // the cap yields for this entry instead.
            guard let oldest = residents
                .filter({ !$0.status.isPending })
                .min(by: { lhs, rhs in
                    let lhsActivity = lhs.standbySince ?? lhs.createdAt
                    let rhsActivity = rhs.standbySince ?? rhs.createdAt
                    if lhsActivity == rhsActivity {
                        return lhs.id < rhs.id
                    }
                    return lhsActivity < rhsActivity
                }) else {
                return
            }
            await closeStandbyAgent(
                id: oldest.id,
                reason: "Standby capacity for this session is limited to "
                    + "\(capacity) agents; the least recently active standby "
                    + "agent was released."
            )
            // Defensive stop: `closeStandbyAgent` always closes a resident, so
            // the loop shrinks the resident set on every iteration.
            guard agents[oldest.id]?.status == .closed else {
                return
            }
        }
    }

    /// Decides whether a task-bound agent whose attempt just completed should
    /// enter standby or be finished normally. Called from `recordCompletion`.
    func concludeTaskBoundTurn(agentID: String) async {
        guard let agent = agents[agentID] else { return }

        // A release requested while this turn was in flight (terminal graph or
        // a newer attempt) wins over re-entering standby.
        if isStandbyResident(agent),
           agent.pendingRelease || agent.supersededByAttemptID != nil {
            await releaseStandbyAgentIfNoLongerEligible(
                agentID: agentID,
                cancellingWorkLoop: false
            )
            return
        }

        // Determine the graph ID from the execution scope.
        let graphID = await resolveGraphID(for: agent)

        if let graphID,
           await isStandbyEligible(agent) {
            await enterStandby(agentID: agentID, graphID: graphID)
            startGraphCompletionObserver(rootSessionID: agent.rootSessionID)
        } else {
            finishTaskBoundAttemptWork(
                for: agentID,
                error: nil,
                discardingPendingPrompts: false
            )
        }
    }

    /// Resolves the graph ID associated with an agent's execution scope.
    func resolveGraphID(for agent: AgentRecord) async -> String? {
        guard let taskOrchestrator,
              let scope = await taskOrchestrator.executionScope(for: agent.sessionID) else {
            return nil
        }
        return scope.graphID
    }

    // MARK: - Coordinated release

    /// Releases every standby resident of the given root session (and
    /// optionally graph). Called when the graph reaches a terminal state, when
    /// a newer attempt supersedes the old one, or at shutdown.
    ///
    /// Residents whose standby turn is still running are flagged
    /// `pendingRelease` instead of being closed mid-response: the release is
    /// completed by `recordStandbyTurnCompletion`/`concludeTaskBoundTurn` when
    /// the in-flight turn lands, so no agent can return to `.standby` after the
    /// graph observer has already stopped.
    func releaseStandbyAgents(
        rootSessionID: String,
        graphID: String?,
        reason: String
    ) async {
        let toRelease = agents.values
            .filter { record in
                isStandbyResident(record)
                    && record.rootSessionID == rootSessionID
                    && (graphID == nil || record.standbyGraphID == graphID)
            }
            .sorted { $0.id < $1.id }
        for record in toRelease {
            guard var current = agents[record.id],
                  isStandbyResident(current) else {
                continue
            }
            current.pendingRelease = true
            current.pendingReleaseReason = reason
            current.updatedAt = .now
            agents[record.id] = current
            guard current.status != .running else {
                // A response is in flight; close it at turn end.
                continue
            }
            await closeStandbyAgent(id: record.id, reason: reason)
        }
    }

    /// Re-evaluates a standby resident and closes it when its standby must end:
    /// a pending release, a newer attempt, an exhausted budget, or any other
    /// loss of eligibility. Returns `true` when the agent was closed.
    ///
    /// Pass `cancellingWorkLoop: false` when calling from inside the agent's own
    /// work loop: the loop observes `.closed` in `nextWork` and exits by itself,
    /// so cancelling it would abort the very task performing the cleanup.
    @discardableResult
    func releaseStandbyAgentIfNoLongerEligible(
        agentID: String,
        cancellingWorkLoop: Bool
    ) async -> Bool {
        guard let agent = agents[agentID],
              isStandbyResident(agent) else {
            return false
        }
        let reason: String
        if agent.pendingRelease {
            reason = agent.pendingReleaseReason ?? Self.standbyReleasedReason
        } else if agent.supersededByAttemptID != nil {
            reason = Self.standbySupersededReason
        } else if agent.standbyTurns >= Self.maximumStandbyTurnsPerAgent {
            reason = Self.standbyBudgetExhaustedReason
        } else if await isStandbyEligible(agent) {
            return false
        } else {
            reason = Self.standbyEndedReason
        }
        await closeStandbyAgent(
            id: agentID,
            reason: reason,
            cancellingWorkLoop: cancellingWorkLoop
        )
        return true
    }

    /// Closes a single standby resident, performing the same cleanup as
    /// `closeAgent` but without attempting to cancel a task attempt (the
    /// attempt is already completed).
    ///
    /// Contract: the target must be a standby resident — a task-bound agent
    /// with a `standbyGraphID` that is not closed. Every standby status is
    /// accepted on purpose: `.standby` (waiting), `.queued`/`.running` (a
    /// follow-up in flight that a release superseded), and `.idle`, which is
    /// where `discardInactiveTaskAttemptWork` leaves a standby agent whose
    /// follow-up was denied. Closing `.idle` residents is what prevents a
    /// budget-exhausted agent from leaking its backend.
    func closeStandbyAgent(
        id: String,
        reason: String,
        cancellingWorkLoop: Bool = true
    ) async {
        guard var agent = agents[id],
              isStandbyResident(agent) else {
            return
        }
        let runTask = cancellingWorkLoop ? agent.runTask : nil
        if cancellingWorkLoop {
            agent.runTask = nil
        }
        agent.pendingPrompts.removeAll()
        agent.pendingOperatorReplyFlags.removeAll()
        agent.pendingRelease = false
        agent.pendingReleaseReason = nil
        agent.status = .closed
        agent.latestError = reason
        agent.currentActivity = nil
        agent.pendingContentBuffer = nil
        agent.currentToolName = nil
        agent.currentToolTarget = nil
        agent.updatedAt = .now
        agents[id] = agent

        runTask?.cancel()
        if let taskOrchestrator {
            await taskOrchestrator.unregisterExecutionScope(
                executionSessionID: agent.sessionID
            )
        }
        await sharedChat.unregisterParticipant(id: agent.id, roomID: agent.rootSessionID)
        // The standby resident ran delegated turns under its own session id, so
        // it owns recall health for that incarnation. This is the single funnel
        // for every standby release — capacity eviction, the periodic reaper,
        // and graph completion — so discarding here covers all three.
        await MemoryTurnCoordinator.shared.discard(sessionID: agent.sessionID)
        await agent.backend.updateBorrowedSubAgentToolExecutor(nil)
        await agent.backend.shutdown()
    }

    // MARK: - Graph completion observer

    /// Starts (if not already running) an observer that watches the task
    /// orchestrator's event stream for the given root session and releases
    /// standby agents when their graph reaches a terminal state.
    func startGraphCompletionObserver(rootSessionID: String) {
        guard graphObserverTasks[rootSessionID] == nil,
              let taskOrchestrator else {
            return
        }
        graphObserverTasks[rootSessionID] = Task(name: "ZenCODE.standby.graph-observer") {
            let stream = await taskOrchestrator.events(sessionID: rootSessionID)
            // Subscribe first, then re-check the snapshot: a graph that became
            // terminal between the standby-eligibility check and this
            // subscription emits no further event, so without this immediate
            // re-check the standby agents would never be released.
            if await self.releaseTerminatedStandbyGraphs(rootSessionID: rootSessionID) {
                self.removeGraphObserver(rootSessionID: rootSessionID)
                return
            }
            for await event in stream {
                guard event.sessionID == rootSessionID,
                      event.graphID != nil else {
                    continue
                }
                // Stop observing once every standby graph of this root session
                // is terminal (or no resident is left to release).
                if await self.releaseTerminatedStandbyGraphs(rootSessionID: rootSessionID) {
                    self.removeGraphObserver(rootSessionID: rootSessionID)
                    break
                }
            }
        }
    }

    /// Releases the standby residents of every graph of this root session that
    /// has reached a terminal state.
    ///
    /// Returns `true` when no standby resident is left for the root session, so
    /// the observer has nothing more to watch and can stop. `enterStandby`
    /// restarts it for the next standby entry.
    func releaseTerminatedStandbyGraphs(rootSessionID: String) async -> Bool {
        guard let taskOrchestrator else {
            return true
        }
        let graphIDs = Set(
            agents.values.compactMap { record -> String? in
                guard record.rootSessionID == rootSessionID,
                      isStandbyResident(record) else {
                    return nil
                }
                return record.standbyGraphID
            }
        )
        guard !graphIDs.isEmpty else {
            return true
        }
        for graphID in graphIDs.sorted() {
            guard let snapshot = try? await taskOrchestrator.graphSnapshot(
                sessionID: rootSessionID,
                graphID: graphID
            ), snapshot.state.isTerminal else {
                continue
            }
            await releaseStandbyAgents(
                rootSessionID: rootSessionID,
                graphID: graphID,
                reason: "Task graph \(graphID) is \(snapshot.state.rawValue)."
            )
        }
        return !agents.values.contains { record in
            record.rootSessionID == rootSessionID && isStandbyResident(record)
        }
    }

    /// Removes and cancels the graph observer for the given root session.
    func removeGraphObserver(rootSessionID: String) {
        graphObserverTasks.removeValue(forKey: rootSessionID)?.cancel()
    }

    // MARK: - Reaper

    /// Ensures the periodic standby reaper is running. The reaper enforces the
    /// idle timeout and turn budget, closing agents that have overstayed. It
    /// captures the runtime weakly and stops as soon as no standby resident is
    /// left, so it never keeps the runtime alive on its own.
    func ensureStandbyReaper() {
        guard standbyReaperTask == nil else { return }
        standbyReaperTask = Task(name: "ZenCODE.standby.reaper") { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(DirectSubAgentRuntime.standbyReaperInterval)
                )
                if Task.isCancelled { return }
                guard let self else { return }
                guard await self.runStandbyReaperCycle(now: .now) else { return }
            }
        }
    }

    /// Runs one reaper cycle and reports whether the reaper should keep going.
    ///
    /// Taking the decision and clearing `standbyReaperTask` in the same
    /// actor-isolated step keeps the handle coherent: once cleared, the exiting
    /// reaper only returns, while `enterStandby` is free to start a fresh one.
    func runStandbyReaperCycle(now: Date) async -> Bool {
        await expireStandbyAgents(now: now)
        guard hasStandbyResidents else {
            standbyReaperTask = nil
            return false
        }
        return true
    }

    /// Stops the reaper when no standby resident is left. Used by the teardown
    /// paths that close agents in bulk.
    func stopStandbyReaperIfIdle() {
        guard !hasStandbyResidents else { return }
        standbyReaperTask?.cancel()
        standbyReaperTask = nil
    }

    /// Closes standby residents whose idle timeout, turn budget, or standby
    /// eligibility is exhausted, including the `.idle` residents left behind by
    /// a denied follow-up, whose backend would otherwise never be shut down.
    func expireStandbyAgents(now: Date) async {
        let residents = agents.values
            .filter { isStandbyResident($0) }
            .sorted { $0.id < $1.id }
        for record in residents {
            // Never interrupt an in-flight standby turn: it is re-evaluated by
            // `recordStandbyTurnCompletion` as soon as the response lands.
            guard !record.status.isPending else { continue }
            let reason: String
            if record.pendingRelease {
                reason = record.pendingReleaseReason ?? Self.standbyReleasedReason
            } else if record.standbyTurns >= Self.maximumStandbyTurnsPerAgent {
                reason = Self.standbyBudgetExhaustedReason
            } else if let standbySince = record.standbySince,
                      now.timeIntervalSince(standbySince) > Self.standbyIdleTimeout {
                reason = Self.standbyIdleTimeoutReason
            } else if await isStandbyEligible(record) {
                continue
            } else {
                reason = Self.standbyEndedReason
            }
            await closeStandbyAgent(id: record.id, reason: reason)
        }
    }

    /// Increment the standby turn counter and refresh the activity timestamp
    /// after a standby turn completes. Called from `recordCompletion` when the
    /// authorization was `.standby`.
    ///
    /// The release conditions are re-evaluated here so a standby turn that was
    /// in flight while the graph completed, or that spent the last turn of the
    /// budget, is closed instead of returning to `.standby`.
    func recordStandbyTurnCompletion(agentID: String) async {
        guard var agent = agents[agentID] else { return }
        agent.standbyTurns += 1
        agent.standbySince = .now
        agent.status = agent.pendingPrompts.isEmpty ? .standby : .queued
        agent.updatedAt = .now
        agents[agentID] = agent
        await releaseStandbyAgentIfNoLongerEligible(
            agentID: agentID,
            cancellingWorkLoop: false
        )
    }

    // MARK: - Release reasons

    static let standbyReleasedReason = "Standby released."
    static let standbySupersededReason = "Superseded by a new task attempt."
    static var standbyBudgetExhaustedReason: String {
        "Standby turn budget exhausted (\(maximumStandbyTurnsPerAgent) turns)."
    }
    static var standbyIdleTimeoutReason: String {
        "Standby idle timeout exceeded (\(Int(standbyIdleTimeout))s)."
    }
    static let standbyEndedReason =
        "Standby ended: this agent is no longer eligible to remain on standby."
}
