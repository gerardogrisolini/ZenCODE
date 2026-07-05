//
//  AgentCoreSessionSupport.swift
//  ZenCODE
//

import Foundation

struct AgentCoreSessionSnapshotRecovery {
    let snapshot: AgentRuntimeSessionSnapshot
    let shouldRestoreBackend: Bool
}

actor AgentCorePromptOutcomeTracker {
    private var didEmitOutcome = false

    func record(_ event: DirectAgentEvent) {
        if case .turnEnded = event {
            didEmitOutcome = true
        }
    }

    func shouldEmitFallback() -> Bool {
        guard !didEmitOutcome else {
            return false
        }
        didEmitOutcome = true
        return true
    }
}

actor AgentCorePromptTurnRecorder {
    private let initialSnapshot: AgentRuntimeSessionSnapshot
    private var history: [AgentRuntimeMessage]
    private var assistantContent = ""
    private var assistantReasoning = ""
    private var assistantToolCalls: [AgentRuntimeToolCall] = []

    init(
        initialSnapshot: AgentRuntimeSessionSnapshot,
        prompt: String,
        attachments: [AgentRuntimeAttachment]
    ) {
        self.initialSnapshot = initialSnapshot
        self.history = initialSnapshot.history

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedPrompt.isEmpty || !attachments.isEmpty {
            history.append(
                AgentRuntimeMessage(
                    role: .user,
                    content: normalizedPrompt,
                    attachments: attachments
                )
            )
        }
    }

    func record(_ event: DirectAgentEvent) {
        switch event {
        case let .thought(delta):
            assistantReasoning.append(delta)
        case let .content(delta):
            assistantContent.append(delta)
        case let .toolCallStarted(toolCall):
            recordToolCall(toolCall)
        case let .toolCallCompleted(toolCall, result):
            recordToolCall(toolCall)
            flushAssistantIfNeeded()
            history.append(
                AgentRuntimeMessage(
                    role: .tool,
                    content: result.modelOutput,
                    toolCallID: toolCall.id,
                    toolName: toolCall.name
                )
            )
        case .status,
             .diagnostic,
             .modelLoaded,
             .modelLoadedDetails,
             .modelRuntime,
             .metrics,
             .contextWindow,
             .subscriptionUsage,
             .sessionSnapshot,
             .turnEnded:
            break
        }
    }

    func snapshot() -> AgentRuntimeSessionSnapshot {
        var snapshotHistory = history
        if let assistantMessage = pendingAssistantMessage() {
            snapshotHistory.append(assistantMessage)
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: initialSnapshot.sessionID,
            modelID: initialSnapshot.modelID,
            workingDirectoryPath: initialSnapshot.workingDirectoryPath,
            systemPrompt: initialSnapshot.systemPrompt,
            cacheKey: initialSnapshot.cacheKey,
            history: snapshotHistory,
            allowedToolNames: initialSnapshot.allowedToolNames,
            thinkingSelection: initialSnapshot.thinkingSelection,
            preserveThinking: initialSnapshot.preserveThinking
        )
    }

    private func recordToolCall(_ toolCall: DirectAgentToolCall) {
        let runtimeToolCall = AgentRuntimeToolCall(
            id: toolCall.id,
            name: toolCall.name,
            argumentsJSON: toolCall.argumentsJSON
        )
        guard !assistantToolCalls.contains(runtimeToolCall) else {
            return
        }
        assistantToolCalls.append(runtimeToolCall)
    }

    private func flushAssistantIfNeeded() {
        guard let assistantMessage = pendingAssistantMessage() else {
            return
        }
        history.append(assistantMessage)
        assistantContent = ""
        assistantReasoning = ""
        assistantToolCalls = []
    }

    private func pendingAssistantMessage() -> AgentRuntimeMessage? {
        let hasContent = !assistantContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasReasoning = !assistantReasoning
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard hasContent || hasReasoning || !assistantToolCalls.isEmpty else {
            return nil
        }
        return AgentRuntimeMessage(
            role: .assistant,
            content: assistantContent,
            reasoningContent: assistantReasoning,
            toolCalls: assistantToolCalls
        )
    }
}

extension AgentRuntimeSessionSnapshot {
    init(configuration: AgentCoreSessionConfiguration) {
        self.init(
            sessionID: configuration.sessionID,
            modelID: configuration.modelID,
            workingDirectoryPath: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            cacheKey: configuration.cacheKey,
            history: configuration.history,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    func isLikelyNewerThan(_ other: AgentRuntimeSessionSnapshot) -> Bool {
        sessionID == other.sessionID && history.count > other.history.count
    }

    func includesLikelyTurn(from recordedSnapshot: AgentRuntimeSessionSnapshot) -> Bool {
        guard sessionID == recordedSnapshot.sessionID else {
            return false
        }
        if history.count >= recordedSnapshot.history.count {
            return true
        }

        let tail = recordedSnapshot.history.suffix(
            min(3, recordedSnapshot.history.count)
        )
        return !tail.isEmpty && tail.allSatisfy { history.contains($0) }
    }
}

extension AgentCoreSessionConfiguration {
    func replacingRuntimeState(
        with snapshot: AgentRuntimeSessionSnapshot
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: snapshot.sessionID,
            modelID: snapshot.modelID ?? modelID,
            bearerToken: bearerToken,
            workingDirectory: URL(fileURLWithPath: snapshot.workingDirectoryPath),
            systemPrompt: snapshot.systemPrompt,
            cacheKey: snapshot.cacheKey,
            sessionRevision: sessionRevision,
            history: snapshot.history,
            allowedToolNames: snapshot.allowedToolNames,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
    }
}
