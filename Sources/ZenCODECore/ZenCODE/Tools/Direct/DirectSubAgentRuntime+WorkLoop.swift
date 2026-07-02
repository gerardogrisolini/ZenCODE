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

            do {
                let response = try await work.backend.sendPrompt(
                    sessionID: work.sessionID,
                    prompt: work.prompt,
                    attachments: [],
                    onEvent: { event in
                        await self.recordEvent(event, agentID: agentID)
                    }
                )
                recordCompletion(response, agentID: agentID)
            } catch is CancellationError {
                recordCancellation(agentID: agentID)
                return
            } catch {
                recordFailure(error, agentID: agentID)
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

    public func recordCompletion(
        _ response: DirectAgentResponse,
        agentID: String
    ) {
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
        agents[agentID] = agent
    }

    public func recordFailure(
        _ error: Error,
        agentID: String
    ) {
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
        agents[agentID] = agent
    }

    public func recordCancellation(agentID: String) {
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
        agents[agentID] = agent
    }
}
