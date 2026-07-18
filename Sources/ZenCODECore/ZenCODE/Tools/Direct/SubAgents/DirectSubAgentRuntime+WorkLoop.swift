//
//  DirectSubAgentRuntime+WorkLoop.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension DirectSubAgentRuntime {
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

            guard await recordTaskAttemptStarted(agentID: agentID) else {
                // A stale queued message must not revive a finished, failed,
                // or retried task attempt.
                discardInactiveTaskAttemptWork(for: agentID)
                return
            }
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
            agent.currentThoughtBuffer = nil
            agent.currentActivity = message.nilIfBlank.map { Self.truncatedActivity($0) }
        case let .diagnostic(message):
            agent.currentThoughtBuffer = nil
            if let message = message.nilIfBlank {
                agent.currentActivity = Self.truncatedActivity(message)
            }
        case let .thought(delta):
            let currentActivity = agent.currentActivity
            if let activity = Self.updatedThoughtActivity(
                currentActivity,
                thoughtBuffer: &agent.currentThoughtBuffer,
                appending: delta
            ) {
                agent.currentActivity = activity
            }
        case let .modelLoaded(modelID):
            agent.currentThoughtBuffer = nil
            agent.modelID = modelID.nilIfBlank ?? agent.modelID
            if let modelID = modelID.nilIfBlank {
                agent.currentActivity = "loaded model \(modelID)"
            }
        case let .modelLoadedDetails(details):
            agent.currentThoughtBuffer = nil
            agent.modelID = details.modelID.nilIfBlank ?? agent.modelID
            agent.modelRuntime = details.runtime ?? agent.modelRuntime
            agent.currentActivity = "loaded model \(details.modelID)"
        case let .modelRuntime(runtime):
            agent.modelRuntime = runtime.nilIfBlank ?? agent.modelRuntime
        case let .content(delta):
            agent.currentThoughtBuffer = nil
            if let preview = Self.updatedStreamingPreview(
                agent.latestContentPreview,
                appending: delta
            ) {
                agent.latestContentPreview = preview
                agent.currentActivity = preview
            }
        case let .toolCallStarted(toolCall):
            agent.currentThoughtBuffer = nil
            agent.currentToolName = toolCall.name
            agent.currentActivity = "running \(toolCall.name)"
        case let .toolCallCompleted(toolCall, result):
            agent.currentThoughtBuffer = nil
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

    private static func updatedThoughtActivity(
        _ currentActivity: String?,
        thoughtBuffer: inout String?,
        appending delta: String
    ) -> String? {
        let prefix = "thinking: "
        if currentActivity?.hasPrefix(prefix) != true {
            thoughtBuffer = nil
        }
        thoughtBuffer = (thoughtBuffer ?? "") + delta
        guard let thought = thoughtBuffer?.nilIfBlank else {
            return currentActivity
        }
        return prefix + truncatedActivity(thought)
    }

    private static func updatedStreamingPreview(
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
        return (try? await taskOrchestrator.markAttemptRunning(
            sessionID: agent.rootSessionID,
            taskID: taskID,
            attemptID: attemptID
        )) ?? false
    }

    public func recordCompletion(
        _ response: DirectAgentResponse,
        agentID: String
    ) async {
        guard var agent = agents[agentID],
              agent.status != .closed else {
            return
        }
        let trimmedOutput = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.latestOutput = trimmedOutput
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
        agent.currentThoughtBuffer = nil
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
            let didComplete = try? await taskOrchestrator.completeAttempt(
                sessionID: agent.rootSessionID,
                taskID: taskID,
                attemptID: attemptID,
                output: agent.latestOutput,
                requiresValidation: false
            )
            if didComplete == true {
                finishTaskBoundAttemptWork(for: agentID, error: nil)
            } else if let currentAgent = agents[agentID] {
                if !(await hasActiveTaskAttempt(currentAgent)) {
                    discardInactiveTaskAttemptWork(for: agentID)
                }
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
            agent.currentThoughtBuffer = nil
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
            agent.currentThoughtBuffer = nil
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
