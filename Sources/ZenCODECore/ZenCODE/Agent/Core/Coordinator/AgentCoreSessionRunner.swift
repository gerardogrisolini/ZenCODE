//
//  AgentCoreSessionRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public actor AgentCoreSessionRunner {
    public static var isAvailable: Bool {
        true
    }

    private var backend: AgentCoreBackend?
    private var activeRuntimeConfiguration: AgentCoreSessionConfiguration?
    private var sessions: [String: AgentCoreSessionConfiguration] = [:]
    private var lastKnownSessionSnapshots: [String: AgentRuntimeSessionSnapshot] = [:]
    private var promptTaskRegistry = AgentCorePromptTaskRegistry()
    private var promptAuthorizationHandlers: [UUID: AgentToolAuthorizationHandler] = [:];
    /// Maps each prompt ID to the session it belongs to so `authorizeTool`
    /// can route authorization requests to the correct handler.
    private var promptAuthorizationSessionIDs: [UUID: String] = [:]
    private let defaultToolAuthorizationHandler: AgentToolAuthorizationHandler?
    let mcpRuntime: DirectMCPToolRuntime
    private let backendFactory: AgentRuntimeBackendFactory?

    public init(
        defaultToolAuthorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) {
        self.defaultToolAuthorizationHandler = defaultToolAuthorizationHandler
        self.mcpRuntime = mcpRuntime
        self.backendFactory = backendFactory
    }

    public func createSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        let backend = try await ensureBackend(configuration: configuration)
        await backend.createSession(
            id: configuration.sessionID,
            cwd: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            history: configuration.history,
            cacheKey: configuration.cacheKey,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
        sessions[configuration.sessionID] = configuration
        ZenLogger.debug(
            .viewModelRuntime,
            "agent core session runner created session id=\(configuration.sessionID) history=\(configuration.history.count) tools=\(configuration.allowedToolNames?.count ?? 0)."
        )
    }

    public func updateSessionOptions(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        let backend = try await ensureBackend(configuration: configuration)
        await backend.updateSessionOptions(
            id: configuration.sessionID,
            systemPrompt: configuration.systemPrompt,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
        sessions[configuration.sessionID] = configuration
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let backend = try await ensureBackend(configuration: configuration)
        return try await backend.preloadModel(onEvent: onEvent)
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration
    ) -> AsyncThrowingStream<DirectAgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DirectAgentEvent, Error>.makeStream()
        let task = Task(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "MLX agent model load"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            do {
                _ = try await preloadModel(configuration: configuration) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                ZenLogger.error(
                    .viewModelRuntime,
                    "agent core session runner preload failed: \(error.localizedDescription)"
                )
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    public func sendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = [],
        borrowedXcodeExecutor: XcodeToolExecutor? = nil,
        borrowedXcodeTools: [ToolDescriptor] = [],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let promptID = UUID()
        if let authorizeTool {
            promptAuthorizationHandlers[promptID] = authorizeTool
            promptAuthorizationSessionIDs[promptID] = configuration.sessionID
        }
        defer {
            promptAuthorizationHandlers.removeValue(forKey: promptID)
            promptAuthorizationSessionIDs.removeValue(forKey: promptID)
        }

        await installBorrowedXcodeExecutor(
            borrowedXcodeExecutor,
            tools: borrowedXcodeTools
        )
        let backend = try await ensureBackend(configuration: configuration)
        await backend.updateBorrowedSubAgentToolExecutor(
            borrowedSubAgentToolExecutor
        )
        await backend.updateToolProviders(toolProviders)
        try await ensureSession(configuration: configuration)
        let initialSnapshot = await backend.snapshotSession(id: configuration.sessionID)
            ?? AgentRuntimeSessionSnapshot(configuration: configuration)
        let turnRecorder = AgentCorePromptTurnRecorder(
            initialSnapshot: initialSnapshot,
            prompt: prompt,
            attachments: attachments
        )

        do {
            let response = try await backend.sendPrompt(
                sessionID: configuration.sessionID,
                prompt: prompt,
                attachments: attachments,
                onEvent: { event in
                    await turnRecorder.record(event)
                    if case let .toolCallStarted(toolCall) = event {
                        await onToolWillExecute?(toolCall)
                    }
                    await onEvent(event)
                }
            )
            await finalizeTurn(
                outcome: .completed,
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                onEvent: onEvent
            )
            return response
        } catch is CancellationError {
            await finalizeTurn(
                outcome: .cancelled,
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                onEvent: onEvent
            )
            throw CancellationError()
        } catch {
            await finalizeTurn(
                outcome: .failed(message: error.localizedDescription),
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                onEvent: onEvent
            )
            throw error
        }
    }

    /// Shared turn-finalization: snapshot, restore, and turn-ended event.
    private func finalizeTurn(
        outcome: DirectAgentTurnOutcome,
        backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration,
        recorder: AgentCorePromptTurnRecorder,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let recovery = await recoveredSessionSnapshot(
            backend: backend,
            configuration: configuration,
            recorder: recorder
        )
        await restoreSessionIfNeeded(
            recovery,
            backend: backend,
            baseConfiguration: configuration
        )
        await onEvent(.sessionSnapshot(recovery.snapshot))
        await onEvent(.turnEnded(outcome))
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        guard let backend else {
            return []
        }
        return await backend.subAgentSnapshots()
    }

    public func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        if let snapshot = await backend?.snapshotSession(id: sessionID) {
            if let lastKnownSnapshot = lastKnownSessionSnapshots[sessionID],
               lastKnownSnapshot.isLikelyNewerThan(snapshot) {
                return lastKnownSnapshot
            }
            return snapshot
        }
        if let snapshot = lastKnownSessionSnapshots[sessionID] {
            return snapshot
        }
        guard let configuration = sessions[sessionID] else {
            return nil
        }
        return AgentRuntimeSessionSnapshot(
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

    @discardableResult
    public func replaceSessionHistory(
        id sessionID: String,
        history: [AgentRuntimeMessage]
    ) async -> Bool {
        guard let baseConfiguration = sessions[sessionID] else {
            return false
        }
        let currentSnapshot = await backend?.snapshotSession(id: sessionID)
            ?? lastKnownSessionSnapshots[sessionID]
            ?? AgentRuntimeSessionSnapshot(configuration: baseConfiguration)
        let replacement = currentSnapshot.replacingHistory(history)
        let replacementConfiguration = baseConfiguration.replacingRuntimeState(
            with: replacement
        )

        sessions[sessionID] = replacementConfiguration
        lastKnownSessionSnapshots[sessionID] = replacement
        if let backend {
            await backend.clearSession(id: sessionID)
            await backend.createSession(
                id: replacement.sessionID,
                cwd: replacement.workingDirectoryPath,
                systemPrompt: replacement.systemPrompt,
                history: replacement.history,
                cacheKey: replacement.cacheKey,
                allowedToolNames: replacement.allowedToolNames,
                thinkingSelection: replacement.thinkingSelection,
                preserveThinking: replacement.preserveThinking
            )
        }
        return true
    }

    public func compactSession(
        id sessionID: String,
        force: Bool = true,
        maxTokensOverride: Int? = nil
    ) async throws -> AgentRuntimeSessionCompactionResult? {
        if promptTaskRegistry.hasActiveTasks(for: sessionID) {
            throw AgentCoreSessionRunnerError.cannotCompactDuringActivePrompt(sessionID)
        }

        let result: AgentRuntimeSessionCompactionResult?
        if let backendResult = await backend?.compactSession(
            id: sessionID,
            force: force,
            maxTokensOverride: maxTokensOverride
        ) {
            result = backendResult
        } else {
            result = compactStoredSession(
                id: sessionID,
                force: force,
                maxTokensOverride: maxTokensOverride
            )
        }
        guard let result else {
            return nil
        }

        cacheCompactedSessionSnapshot(result.snapshot)
        return result
    }

    public func saveSessionRuntimeCache(id sessionID: String) async {
        await backend?.saveSessionRuntimeCache(id: sessionID)
    }

    public func restoreSessionRuntimeCache(id sessionID: String) async {
        await backend?.restoreSessionRuntimeCache(id: sessionID)
    }

    /// Shared session-restore entry point: creates the runtime session and
    /// rehydrates its KV cache from disk for the same session identity. Both
    /// the TUI saved-session loader and the ACP session/load and
    /// session/resume flows use this so cache loading stays unified.
    public func restoreSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        try await createSession(configuration: configuration)
        await restoreSessionRuntimeCache(id: configuration.sessionID)
    }


    public func streamPrompt(
        _ prompt: String,
        configuration: AgentCoreSessionConfiguration,
        attachments: [AgentRuntimeAttachment] = [],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = [],
        borrowedXcodeExecutor: XcodeToolExecutor? = nil,
        borrowedXcodeTools: [ToolDescriptor] = []
    ) -> AsyncThrowingStream<DirectAgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DirectAgentEvent, Error>.makeStream()
        let promptID = UUID()
        let outcomeTracker = AgentCorePromptOutcomeTracker()
        let task = Task(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "MLX agent generation"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            do {
                _ = try await sendPrompt(
                    configuration: configuration,
                    prompt: prompt,
                    attachments: attachments,
                    authorizeTool: authorizeTool,
                    onToolWillExecute: onToolWillExecute,
                    borrowedSubAgentToolExecutor: borrowedSubAgentToolExecutor,
                    toolProviders: toolProviders,
                    borrowedXcodeExecutor: borrowedXcodeExecutor,
                    borrowedXcodeTools: borrowedXcodeTools
                ) { event in
                    await outcomeTracker.record(event)
                    continuation.yield(event)
                }
                await finishStream(continuation, outcomeTracker: outcomeTracker, promptID: promptID, error: nil)
            } catch is CancellationError {
                await finishStream(continuation, outcomeTracker: outcomeTracker, promptID: promptID, error: CancellationError())
            } catch {
                ZenLogger.error(
                    .viewModelRuntime,
                    "agent core session runner stream failed: \(error.localizedDescription)"
                )
                await finishStream(continuation, outcomeTracker: outcomeTracker, promptID: promptID, error: error)
            }
        }
        promptTaskRegistry.register(task, id: promptID, sessionID: configuration.sessionID)
        continuation.onTermination = { _ in
            task.cancel()
            Task {
                await self.clearActivePromptTask(id: promptID)
            }
        }
        return stream
    }

    /// Shared stream-finalization: emits fallback turn-ended event if needed,
    /// clears the task, and finishes the continuation.
    private func finishStream(
        _ continuation: AsyncThrowingStream<DirectAgentEvent, Error>.Continuation,
        outcomeTracker: AgentCorePromptOutcomeTracker,
        promptID: UUID,
        error: Error?
    ) async {
        if error == nil, await outcomeTracker.shouldEmitFallback() {
            continuation.yield(.turnEnded(.completed))
        } else if error is CancellationError, await outcomeTracker.shouldEmitFallback() {
            continuation.yield(.turnEnded(.cancelled))
        } else if error != nil, await outcomeTracker.shouldEmitFallback() {
            continuation.yield(.turnEnded(.failed(message: error!.localizedDescription)))
        }
        clearActivePromptTask(id: promptID)
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    public func cancelActivePrompt() async {
        promptTaskRegistry.cancelAllTasks()
        promptAuthorizationHandlers.removeAll()
    }

    public func cancelPrompt(sessionID: String) async {
        promptTaskRegistry.cancelAll(for: sessionID)
    }

    public func resetSession(id sessionID: String? = nil) async {
        if let sessionID {
            promptTaskRegistry.cancelAll(for: sessionID)
            sessions.removeValue(forKey: sessionID)
            lastKnownSessionSnapshots.removeValue(forKey: sessionID)
            await backend?.clearSession(id: sessionID)
            return
        }

        promptTaskRegistry.cancelAllTasks()
        promptAuthorizationHandlers.removeAll()

        let sessionIDs = Array(sessions.keys)
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        for sessionID in sessionIDs {
            await backend?.clearSession(id: sessionID)
        }
    }

    public func closeSession(id sessionID: String) async {
        promptTaskRegistry.cancelAll(for: sessionID)
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
        await backend?.closeSession(id: sessionID)
    }

    public func shutdown() async {
        await shutdownBackendKeepingExternalTools()
        await mcpRuntime.shutdown()
    }

    /// Shuts down the model backend and all session state while keeping the
    /// connected external MCP servers (for example the already-authorized
    /// Xcode connection) alive. Use this for in-process resets such as model
    /// or agent switching, where tearing down MCP connections would force the
    /// user to grant external-tool consents again.
    public func shutdownBackendKeepingExternalTools() async {
        promptTaskRegistry.cancelAllTasks()
        promptAuthorizationHandlers.removeAll()
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        activeRuntimeConfiguration = nil
        let backendToShutdown = backend
        backend = nil
        await backendToShutdown?.shutdown()
    }

    private func registerActivePromptTask(
        _ task: Task<Void, Never>,
        id promptID: UUID,
        sessionID: String
    ) {
        promptTaskRegistry.register(task, id: promptID, sessionID: sessionID)
    }

    private func cancelPromptTasks(for sessionID: String) {
        promptTaskRegistry.cancelAll(for: sessionID)
    }

    private func clearActivePromptTask(id promptID: UUID) {
        promptTaskRegistry.clear(id: promptID)
        promptAuthorizationHandlers.removeValue(forKey: promptID)
    }

    private func ensureSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        if let existing = sessions[configuration.sessionID] {
            if existing.matchesSessionIdentity(configuration) {
                return
            }
            if existing.matchesSessionIdentityIgnoringThinking(configuration) {
                try await updateSessionOptions(configuration: configuration)
                return
            }
        }
        try await createSession(configuration: configuration)
    }

    private func ensureBackend(
        configuration: AgentCoreSessionConfiguration
    ) async throws -> AgentCoreBackend {
        if let activeRuntimeConfiguration,
           !activeRuntimeConfiguration.matchesRuntime(configuration) {
            await resetBackend()
        }

        if let backend {
            return backend
        }

        let runtimeConfiguration = configuration.runtimeConfiguration
            .withToolAuthorizationHandler { request in
                await self.authorizeTool(request)
            }
        let backend = AgentCoreBackend(
            configuration: runtimeConfiguration,
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory
        )
        self.backend = backend
        activeRuntimeConfiguration = configuration
        ZenLogger.debug(
            .viewModelRuntime,
            "agent core session runner initialized model=\(configuration.modelID ?? "default") cwd=\(configuration.workingDirectoryPath)."
        )
        return backend
    }

    private func resetBackend() async {
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        activeRuntimeConfiguration = nil
        await backend?.shutdown()
        backend = nil
    }

    private func recoveredSessionSnapshot(
        backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration,
        recorder: AgentCorePromptTurnRecorder
    ) async -> AgentCoreSessionSnapshotRecovery {
        let recordedSnapshot = await recorder.snapshot()
        if let backendSnapshot = await backend.snapshotSession(id: configuration.sessionID),
           backendSnapshot.includesLikelyTurn(from: recordedSnapshot) {
            cacheSessionSnapshot(backendSnapshot, baseConfiguration: configuration)
            return AgentCoreSessionSnapshotRecovery(
                snapshot: backendSnapshot,
                shouldRestoreBackend: false
            )
        }

        cacheSessionSnapshot(recordedSnapshot, baseConfiguration: configuration)
        return AgentCoreSessionSnapshotRecovery(
            snapshot: recordedSnapshot,
            shouldRestoreBackend: true
        )
    }

    private func restoreSessionIfNeeded(
        _ recovery: AgentCoreSessionSnapshotRecovery,
        backend: AgentCoreBackend,
        baseConfiguration: AgentCoreSessionConfiguration
    ) async {
        guard recovery.shouldRestoreBackend else {
            return
        }
        let configuration = baseConfiguration.replacingRuntimeState(
            with: recovery.snapshot
        )
        await backend.createSession(
            id: configuration.sessionID,
            cwd: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            history: configuration.history,
            cacheKey: configuration.cacheKey,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    private func cacheSessionSnapshot(
        _ snapshot: AgentRuntimeSessionSnapshot,
        baseConfiguration: AgentCoreSessionConfiguration
    ) {
        lastKnownSessionSnapshots[snapshot.sessionID] = snapshot
        sessions[snapshot.sessionID] = baseConfiguration.replacingRuntimeState(
            with: snapshot
        )
    }

    private func compactStoredSession(
        id sessionID: String,
        force: Bool,
        maxTokensOverride: Int?
    ) -> AgentRuntimeSessionCompactionResult? {
        let baseConfiguration: AgentCoreSessionConfiguration
        let currentSnapshot: AgentRuntimeSessionSnapshot
        if let snapshot = lastKnownSessionSnapshots[sessionID],
           let configuration = sessions[sessionID] {
            baseConfiguration = configuration
            currentSnapshot = snapshot
        } else if let configuration = sessions[sessionID] {
            baseConfiguration = configuration
            currentSnapshot = AgentRuntimeSessionSnapshot(configuration: configuration)
        } else {
            return nil
        }

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            currentSnapshot.compactionInputMessages,
            maxTokens: maxTokensOverride ?? baseConfiguration.configuredContextWindowLimit,
            force: force
        )
        guard result.wasCompacted else {
            return nil
        }

        return AgentRuntimeSessionCompactionResult(
            snapshot: currentSnapshot.applyingCompaction(result),
            compactionResult: result
        )
    }

    private func cacheCompactedSessionSnapshot(
        _ snapshot: AgentRuntimeSessionSnapshot
    ) {
        lastKnownSessionSnapshots[snapshot.sessionID] = snapshot
        if let configuration = sessions[snapshot.sessionID] {
            sessions[snapshot.sessionID] = configuration.replacingRuntimeState(with: snapshot)
        }
    }

    private func authorizeTool(_ request: AgentToolAuthorizationRequest) async -> Bool {
        // Route authorization to the handler registered for the session that
        // owns the tool call, falling back to the first available handler
        // (for backwards compatibility) and finally the default handler.
        let sessionID = request.sessionID

        // Explicit session match first.
        for (promptID, handler) in promptAuthorizationHandlers {
            if promptAuthorizationSessionIDs[promptID] == sessionID {
                return await handler(request)
            }
        }
        // Fallback: first registered handler (legacy behaviour).
        if let handler = promptAuthorizationHandlers.first?.value {
            return await handler(request)
        }
        guard let defaultToolAuthorizationHandler else {
            return true
        }
        return await defaultToolAuthorizationHandler(request)
    }
}
