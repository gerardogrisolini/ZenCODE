//
//  DirectSubAgentRuntime+WorkLoop.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension DirectSubAgentRuntime {
    public func queuePrompt(_ prompt: String, for agentID: String) throws {
        try validateImplementationPromptTargets([agentID])
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

    func validateImplementationPayloads(
        _ payloads: [RequestedAgentPayload]
    ) throws {
        let promptedImplementations = payloads.filter {
            $0.isolationMode == .implementation && $0.prompt != nil
        }
        guard promptedImplementations.count <= 1 else {
            throw DirectSubAgentRuntimeError.unsafeImplementationParallelism
        }
        if !promptedImplementations.isEmpty,
           agents.values.contains(where: {
               $0.isolationMode == .implementation && $0.status.isPending
           }) {
            throw DirectSubAgentRuntimeError.unsafeImplementationParallelism
        }
    }

    func validateImplementationPromptTargets(_ agentIDs: [String]) throws {
        let targetIDs = Set(agentIDs)
        let implementationTargetIDs = targetIDs.filter {
            agents[$0]?.isolationMode == .implementation
        }
        guard implementationTargetIDs.count <= 1 else {
            throw DirectSubAgentRuntimeError.unsafeImplementationParallelism
        }
        guard !implementationTargetIDs.isEmpty else { return }

        let anotherWriterIsActive = agents.values.contains { agent in
            agent.isolationMode == .implementation
                && agent.status.isPending
                && !targetIDs.contains(agent.id)
        }
        guard !anotherWriterIsActive else {
            throw DirectSubAgentRuntimeError.unsafeImplementationParallelism
        }
    }

    public func startAgentIfNeeded(agentID: String) {
        guard var agent = agents[agentID],
              agent.runTask == nil else {
            return
        }

        agent.runTask = Task {
            await self.runAgentLoop(agentID: agentID)
        }
        agents[agentID] = agent
    }

    public func runAgentLoop(agentID: String) async {
        while true {
            guard let work = nextWork(for: agentID) else {
                return
            }

            await recordTaskAttemptStarted(agentID: agentID)
            do {
                let response = try await work.backend.sendPrompt(
                    sessionID: work.sessionID,
                    prompt: work.prompt,
                    attachments: [],
                    onEvent: { event in
                        await self.recordEvent(event, agentID: agentID)
                    }
                )
                await recordCompletion(response, agentID: agentID)
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
            if agent.status != .failed {
                agent.status = .idle
            }
            agent.updatedAt = .now
            agents[agentID] = agent
            return nil
        }

        let prompt = agent.pendingPrompts.removeFirst()
        agent.status = .running
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
        case let .status(message):
            agent.currentActivity = message.nilIfBlank.map { Self.truncatedActivity($0) }
        case let .diagnostic(message):
            if let message = message.nilIfBlank {
                agent.currentActivity = Self.truncatedActivity(message)
            }
        case let .thought(delta):
            if let thought = delta.nilIfBlank {
                agent.currentActivity = "thinking: \(Self.truncatedActivity(thought))"
            }
        case let .modelLoaded(modelID):
            agent.modelID = modelID.nilIfBlank ?? agent.modelID
            if let modelID = modelID.nilIfBlank {
                agent.currentActivity = "loaded model \(modelID)"
            }
        case let .modelLoadedDetails(details):
            agent.modelID = details.modelID.nilIfBlank ?? agent.modelID
            agent.modelRuntime = details.runtime ?? agent.modelRuntime
            agent.currentActivity = "loaded model \(details.modelID)"
        case let .modelRuntime(runtime):
            agent.modelRuntime = runtime.nilIfBlank ?? agent.modelRuntime
        case let .content(delta):
            if let preview = Self.updatedPreview(agent.latestContentPreview, appending: delta) {
                agent.latestContentPreview = preview
                agent.currentActivity = preview
            }
        case let .toolCallStarted(toolCall):
            agent.currentToolName = toolCall.name
            agent.currentActivity = "running \(toolCall.name)"
        case let .toolCallCompleted(toolCall, result):
            agent.currentToolName = nil
            let summary = result.summary.nilIfBlank ?? result.output.nilIfBlank
            agent.currentActivity = summary.map { "completed \(toolCall.name): \(Self.truncatedActivity($0))" }
                ?? "completed \(toolCall.name)"
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

    private static func updatedPreview(
        _ current: String?,
        appending delta: String
    ) -> String? {
        let combined = ((current ?? "") + delta)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            return current
        }
        return truncatedActivity(combined)
    }

    private static func truncatedActivity(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let limit = 180
        guard normalized.count > limit else {
            return normalized
        }
        return String(normalized.prefix(limit - 1)) + "…"
    }

    public func recordTaskAttemptStarted(agentID: String) async {
        guard let agent = agents[agentID],
              let taskID = agent.taskID,
              let attemptID = agent.taskAttemptID,
              let taskOrchestrator else {
            return
        }
        _ = try? await taskOrchestrator.markAttemptRunning(
            sessionID: agent.rootSessionID,
            taskID: taskID,
            attemptID: attemptID
        )
    }

    public func recordCompletion(
        _ response: DirectAgentResponse,
        agentID: String
    ) async {
        guard var agent = agents[agentID],
              agent.status != .closed else {
            return
        }
        agent.latestOutput = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.latestError = nil
        agent.modelID = response.modelID.nilIfBlank ?? agent.modelID
        agent.currentActivity = nil
        agent.currentToolName = nil
        agent.latestContentPreview = nil
        agent.status = agent.pendingPrompts.isEmpty ? .idle : .queued
        agent.updatedAt = .now
        let releasedReservation = agent.pendingPrompts.isEmpty
            ? takeTasklessDelegationReservation(from: &agent)
            : nil
        if releasedReservation != nil {
            // Keep the agent pending until the cross-actor lease release has
            // completed, so graph activation cannot race an apparently idle
            // taskless agent.
            agent.status = .running
        }
        agents[agentID] = agent
        if let taskID = agent.taskID,
           let attemptID = agent.taskAttemptID,
           let taskOrchestrator {
            _ = try? await taskOrchestrator.completeAttempt(
                sessionID: agent.rootSessionID,
                taskID: taskID,
                attemptID: attemptID,
                output: agent.latestOutput,
                requiresValidation: agent.isolationMode == .implementation
            )
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
            agent.currentToolName = nil
        }
        agent.updatedAt = .now
        let releasedReservation = takeTasklessDelegationReservation(from: &agent)
        agents[agentID] = agent
        if let taskID = agent.taskID,
           let attemptID = agent.taskAttemptID,
           let taskOrchestrator {
            _ = try? await taskOrchestrator.failAttempt(
                sessionID: agent.rootSessionID,
                taskID: taskID,
                attemptID: attemptID,
                error: error.localizedDescription,
                output: agent.latestOutput
            )
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
            agent.currentToolName = nil
        }
        agent.updatedAt = .now
        let releasedReservation = takeTasklessDelegationReservation(from: &agent)
        agents[agentID] = agent
        if let taskID = agent.taskID,
           let attemptID = agent.taskAttemptID,
           let taskOrchestrator {
            _ = try? await taskOrchestrator.cancelAttempt(
                sessionID: agent.rootSessionID,
                taskID: taskID,
                attemptID: attemptID,
                reason: "Delegated sub-agent cancelled."
            )
        }
        await releaseTasklessDelegationReservation(releasedReservation)
    }
}
