import ToolCore
@testable import ZenCODECore

actor CapturingSubAgentRuntimeBackend: AgentRuntimeBackend {
    struct CreatedSession: Sendable {
        let id: String
        let cwd: String
        let cacheKey: String?
        let historyCount: Int
        let systemPrompt: String?
        let allowedToolNames: Set<String>?
    }

    private var thinkingSelection: AgentThinkingSelection?
    private var sessions: [CreatedSession] = []
    private let responseText: String
    private let blocksPrompts: Bool
    private let failsPrompts: Bool
    private let borrowedToolCallOnPrompt: AgentBorrowedToolCall?
    private var sentPrompts: [String] = []
    private var sentPromptCountWaiters: [SentPromptCountWaiter] = []
    // A shared fixture may serve multiple roots. Keep blocked turns keyed by
    // their backend session so cancellation of one runtime cannot release the
    // other runtime's prompt.
    private var blockedPromptContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var blockedPromptCancellationRequests: Set<String> = []
    private var shutdownCalls = 0
    private var shutdownCountWaiters: [ShutdownCountWaiter] = []
    private var installedTaskOrchestrator = false
    private var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?
    private var subAgentToolEventHandler: DirectSubAgentToolEventHandler?
    private(set) var toolProviderUpdates: [(providers: [AgentToolProvider], sessionID: String?)] = []

    private struct SentPromptCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct ShutdownCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        responseText: String = "done",
        blocksPrompts: Bool = false,
        failsPrompts: Bool = false,
        borrowedToolCallOnPrompt: AgentBorrowedToolCall? = nil
    ) {
        self.responseText = responseText
        self.blocksPrompts = blocksPrompts
        self.failsPrompts = failsPrompts
        self.borrowedToolCallOnPrompt = borrowedToolCallOnPrompt
    }

    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        installedTaskOrchestrator = true
    }

    func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        borrowedSubAgentToolExecutor = executor
    }

    func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {
        subAgentToolEventHandler = handler
    }

    func executeBorrowedSubAgentTool(_ toolCall: AgentBorrowedToolCall) async throws -> String {
        guard let borrowedSubAgentToolExecutor else {
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        return try await borrowedSubAgentToolExecutor(toolCall)
    }

    func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String?
    ) async {
        toolProviderUpdates.append((providers, sessionID))
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        sessions.append(
            CreatedSession(
                id: id,
                cwd: cwd,
                cacheKey: cacheKey,
                historyCount: history.count,
                systemPrompt: systemPrompt,
                allowedToolNames: allowedToolNames
            )
        )
        self.thinkingSelection = thinkingSelection
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
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

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() {
        shutdownCalls += 1
        resumeShutdownCountWaiters()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        sentPrompts.append(prompt)
        resumeSentPromptCountWaiters()
        if let borrowedToolCallOnPrompt, let borrowedSubAgentToolExecutor {
            _ = try await borrowedSubAgentToolExecutor(borrowedToolCallOnPrompt)
        }
        if blocksPrompts {
            // `AgentRuntimeBackend.shutdown()` has no session/root argument.
            // Let cancellation of the owning work loop release this turn
            // instead of making shutdown resume every shared-fixture waiter.
            await withTaskCancellationHandler {
                await waitForBlockedPromptRelease(sessionID: sessionID)
            } onCancel: {
                Task {
                    await self.cancelBlockedPrompt(sessionID: sessionID)
                }
            }
            try Task.checkCancellation()
        }
        if failsPrompts {
            throw DirectSubAgentRuntimeError.agentNotFound("intentional failure")
        }
        return DirectAgentResponse(
            text: responseText,
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func didInstallTaskOrchestrator() -> Bool {
        installedTaskOrchestrator
    }

    func hasSubAgentToolEventHandler() -> Bool {
        subAgentToolEventHandler != nil
    }

    func createdThinkingSelection() -> AgentThinkingSelection? {
        thinkingSelection
    }

    func createdSessions() -> [CreatedSession] {
        sessions
    }

    func sentPromptCount() -> Int {
        sentPrompts.count
    }

    func waitUntilSentPromptCount(_ count: Int) async {
        guard sentPrompts.count < count else { return }
        await withCheckedContinuation { continuation in
            sentPromptCountWaiters.append(
                SentPromptCountWaiter(count: count, continuation: continuation)
            )
        }
    }

    func shutdownCount() -> Int {
        shutdownCalls
    }

    func waitUntilShutdownCount(_ count: Int) async {
        guard shutdownCalls < count else { return }
        await withCheckedContinuation { continuation in
            shutdownCountWaiters.append(
                ShutdownCountWaiter(count: count, continuation: continuation)
            )
        }
    }

    private func resumeSentPromptCountWaiters() {
        let ready = sentPromptCountWaiters.filter { sentPrompts.count >= $0.count }
        sentPromptCountWaiters.removeAll { sentPrompts.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func waitForBlockedPromptRelease(sessionID: String) async {
        if blockedPromptCancellationRequests.remove(sessionID) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if blockedPromptCancellationRequests.remove(sessionID) != nil {
                continuation.resume()
            } else {
                blockedPromptContinuations[sessionID] = continuation
            }
        }
    }

    private func cancelBlockedPrompt(sessionID: String) {
        if let continuation = blockedPromptContinuations.removeValue(forKey: sessionID) {
            continuation.resume()
        } else {
            blockedPromptCancellationRequests.insert(sessionID)
        }
    }

    private func resumeShutdownCountWaiters() {
        let ready = shutdownCountWaiters.filter { shutdownCalls >= $0.count }
        shutdownCountWaiters.removeAll { shutdownCalls >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
