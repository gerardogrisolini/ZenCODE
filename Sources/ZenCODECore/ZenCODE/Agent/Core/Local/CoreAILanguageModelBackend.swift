#if os(macOS) && canImport(CoreAILanguageModels) && canImport(FoundationModels)

//
//  CoreAILanguageModelBackend.swift
//  ZenCODE
//
//  Minimal AgentRuntimeBackend adapter for Apple's Core AI language-model
//  package. The package exposes a FoundationModels LanguageModel; all agent
//  lifecycle and persistence state remains in this adapter and ZenCODE's
//  existing coordinator.
//

import CoreAILanguageModels
import Foundation
import FoundationModels
import ToolCore

@available(macOS 27.0, *)
public actor CoreAILanguageModelBackend: AgentRuntimeBackend {
    private struct SessionState {
        let id: String
        let cwd: URL
        let cacheKey: String?
        var systemPrompt: String?
        var allowedToolNames: Set<String>?
        var thinkingSelection: AgentThinkingSelection?
        var preserveThinking: Bool
        var messages: [AgentRuntimeMessage]
        var languageSession: LanguageModelSession?
        var isResponding: Bool
    }

    public let configuration: AgentRuntimeConfiguration
    public let resourcesURL: URL
    public let toolExecutor: DirectToolExecutor

    private var model: CoreAILanguageModel?
    private var modelLoadTask: Task<CoreAILanguageModel, Error>?
    private var sessions: [String: SessionState] = [:]
    private var didEmitLoadedModel = false

    public init(
        configuration: AgentRuntimeConfiguration,
        resourcesURL: URL,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        subAgentContextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.configuration = configuration
        self.resourcesURL = resourcesURL.standardizedFileURL
        self.toolExecutor = DirectToolExecutor(
            authorizationHandler: configuration.toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: swiftFeatureRuntime ?? SwiftFeatureRuntime(),
            preferredWorkspaceRootURL: configuration.workingDirectory,
            subAgentContextualBackendFactory: subAgentContextualBackendFactory
                ?? DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
    }

    public func createSession(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        sessions[id] = SessionState(
            id: id,
            cwd: URL(fileURLWithPath: cwd).standardizedFileURL,
            cacheKey: cacheKey,
            systemPrompt: systemPrompt,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking,
            messages: history,
            languageSession: nil,
            isResponding: false
        )
    }

    public func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        guard sessions[id] == nil else {
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    public func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
        session.systemPrompt = systemPrompt
        session.allowedToolNames = allowedToolNames
        session.thinkingSelection = thinkingSelection
        session.preserveThinking = preserveThinking
        // Instructions are part of the Foundation Models session identity. A
        // changed system prompt therefore gets a fresh session while our
        // durable message history remains unchanged.
        session.languageSession = nil
        sessions[id] = session
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        await toolExecutor.installTaskOrchestrator(orchestrator)
    }

    public func closeSubAgent(id: String) async -> Bool {
        await toolExecutor.closeSubAgent(id: id)
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        await toolExecutor.interruptSubAgents(rootSessionID: rootSessionID)
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedSubAgentToolExecutor(executor)
    }

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String? = nil
    ) async {
        await toolExecutor.updateToolProviders(providers, sessionID: sessionID)
    }

    public func closeSession(id: String) async {
        sessions.removeValue(forKey: id)
        await toolExecutor.removeToolProviders(sessionID: id)
    }

    public func shutdown() async {
        sessions.removeAll()
        await toolExecutor.shutdown()
        model?.unload()
        model = nil
    }

    public func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        guard var session = sessions[id] else {
            return nil
        }
        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            session.messages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: configuration.configuredContextWindowLimit,
                maxOutputTokens: configuration.maxOutputTokens
            ),
            force: force
        )
        guard result.wasCompacted else {
            return nil
        }

        session.messages = result.messages
        session.languageSession = nil
        sessions[id] = session
        guard let snapshot = snapshotSession(id: id) else {
            return nil
        }
        return AgentRuntimeSessionCompactionResult(
            snapshot: snapshot,
            compactionResult: result
        )
    }

    public func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        _ = try await loadModel()
        let modelID = configuration.modelID ?? CoreAILocalModelSupport.qwenModelID
        if !didEmitLoadedModel {
            didEmitLoadedModel = true
            await onEvent(.modelLoaded(modelID))
        }
        return modelID
    }

    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await activeToolDescriptors(sessionID: nil)
    }

    public func activeToolDescriptors(
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        let session = if let sessionID {
            sessions[sessionID]
        } else {
            sessions.values.first
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session?.allowedToolNames,
            preferredWorkspaceRootURL: session?.cwd,
            sessionID: session?.id
        )
    }

    public func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let session = sessions[id] else {
            return nil
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: configuration.modelID ?? CoreAILocalModelSupport.qwenModelID,
            workingDirectoryPath: session.cwd.path,
            systemPrompt: session.systemPrompt,
            cacheKey: session.cacheKey,
            history: session.messages,
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            preserveThinking: session.preserveThinking
        )
    }

    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(
                id: sessionID,
                cwd: configuration.workingDirectory.path
            )
        }
        guard var session = sessions[sessionID] else {
            throw CoreAILocalBackendError.missingSession(sessionID)
        }
        guard !session.isResponding else {
            throw CoreAILocalBackendError.concurrentRequest(sessionID)
        }
        guard attachments.isEmpty else {
            throw CoreAILocalBackendError.unsupportedAttachments
        }

        // Claim the session synchronously, before any suspension point. The
        // actor is reentrant while `await loadModel()` runs below, so a
        // concurrent `sendPrompt` on this session would otherwise observe
        // `isResponding == false` and start a second generation (TOCTOU on the
        // guard above). The claim is released again in every failure path.
        session.isResponding = true
        sessions[sessionID] = session

        do {
            let model = try await loadModel()
            guard var claimedSession = sessions[sessionID] else {
                throw CoreAILocalBackendError.missingSession(sessionID)
            }
            claimedSession.messages.append(
                AgentRuntimeMessage(role: .user, content: prompt)
            )
            if claimedSession.languageSession == nil {
                claimedSession.languageSession = LanguageModelSession(
                    model: model,
                    instructions: Self.instructions(
                        systemPrompt: claimedSession.systemPrompt,
                        history: Array(claimedSession.messages.dropLast())
                    )
                )
            }
            guard let languageSession = claimedSession.languageSession else {
                throw CoreAILocalBackendError.invalidResources(
                    resourcesURL,
                    "Unable to initialize LanguageModelSession."
                )
            }
            sessions[sessionID] = claimedSession

            let startedAt = Date()
            let options = GenerationOptions(
                maximumResponseTokens: configuration.maxOutputTokens
            )
            let stream = languageSession.streamResponse(to: prompt, options: options)
            var responseText = ""
            for try await snapshot in stream {
                try Task.checkCancellation()
                let snapshotText = snapshot.content
                let delta: String
                if snapshotText.hasPrefix(responseText) {
                    delta = String(snapshotText.dropFirst(responseText.count))
                } else {
                    // Foundation Models normally yields cumulative snapshots;
                    // tolerate a replacement snapshot without duplicating text.
                    delta = snapshotText
                }
                responseText = snapshotText
                if !delta.isEmpty {
                    await onEvent(.content(delta))
                }
            }

            guard var completedSession = sessions[sessionID] else {
                throw CoreAILocalBackendError.missingSession(sessionID)
            }
            completedSession.messages.append(
                AgentRuntimeMessage(role: .assistant, content: responseText)
            )
            completedSession.isResponding = false
            sessions[sessionID] = completedSession

            let usage = languageSession.usage
            await onEvent(
                .metrics(
                    DirectAgentGenerationMetrics(
                        promptTokenCount: usage.input.totalTokenCount,
                        cachedPromptTokenCount: usage.input.cachedTokenCount,
                        promptTokensPerSecond: nil,
                        completionTokenCount: usage.output.totalTokenCount,
                        completionTokensPerSecond: nil,
                        responseDurationSeconds: Date().timeIntervalSince(startedAt),
                        contextTokenCount: usage.totalTokenCount
                    )
                )
            )
            return DirectAgentResponse(
                text: responseText,
                stopReason: "stop",
                modelID: configuration.modelID ?? CoreAILocalModelSupport.qwenModelID
            )
        } catch is CancellationError {
            markGenerationFinished(sessionID: sessionID)
            throw CancellationError()
        } catch let error as CoreAILocalBackendError {
            markGenerationFinished(sessionID: sessionID)
            throw error
        } catch {
            markGenerationFinished(sessionID: sessionID)
            throw CoreAILocalBackendError.generationFailed(error.localizedDescription)
        }
    }

    private func markGenerationFinished(sessionID: String) {
        guard var session = sessions[sessionID] else {
            return
        }
        session.isResponding = false
        sessions[sessionID] = session
    }

    private func loadModel() async throws -> CoreAILanguageModel {
        if let model {
            return model
        }
        // The actor is reentrant while the model loads, so two sessions can
        // race through the `if let model` check above. Share a single load
        // task instead of constructing the model twice.
        if let modelLoadTask {
            return try await modelLoadTask.value
        }
        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            throw CoreAILocalBackendError.missingResources(resourcesURL)
        }
        let task = Task {
            // This is the public upstream Core AI API. The package validates
            // and loads the model resources from the supplied bundle URL.
            try await CoreAILanguageModel(resourcesAt: resourcesURL)
        }
        modelLoadTask = task
        do {
            let loadedModel = try await task.value
            model = loadedModel
            modelLoadTask = nil
            return loadedModel
        } catch let error as CoreAILocalBackendError {
            modelLoadTask = nil
            throw error
        } catch {
            modelLoadTask = nil
            throw CoreAILocalBackendError.invalidResources(
                resourcesURL,
                error.localizedDescription
            )
        }
    }

    private static func instructions(
        systemPrompt: String?,
        history: [AgentRuntimeMessage]
    ) -> String? {
        var sections: [String] = []
        if let systemPrompt = systemPrompt?.nilIfBlank {
            sections.append(systemPrompt)
        }
        let historyLines = history.compactMap { message -> String? in
            let content = message.content.nilIfBlank ?? ""
            guard !content.isEmpty else { return nil }
            return "[\(message.role.rawValue)]\n\(content)"
        }
        if !historyLines.isEmpty {
            sections.append(
                "Previous conversation (continue from this context):\n"
                    + historyLines.joined(separator: "\n\n")
            )
        }
        return sections.joined(separator: "\n\n").nilIfBlank
    }
}

#endif
