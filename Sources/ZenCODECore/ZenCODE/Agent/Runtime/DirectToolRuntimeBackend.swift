import Foundation

/// Opt-in forwarding for backends that already own a direct-tool executor.
/// Keep provider/session lifecycle outside this adapter; in particular, providers
/// may override catalogue updates to invalidate their request-budget caches.
/// The base backend defaults remain available to external implementations that
/// do not use direct tools. Public methods preserve concrete client access.
protocol DirectToolRuntimeBackend: AgentRuntimeBackend {
    var toolExecutor: DirectToolExecutor { get }
}

extension DirectToolRuntimeBackend {
    public func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await activeToolDescriptors(sessionID: nil)
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

    public func interruptBackgroundJobs() async -> Int {
        await toolExecutor.interruptBackgroundJobs()
    }

    public func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] {
        await toolExecutor.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        try await sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: UUID()
        )
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID
    ) async throws -> AgentSharedChat.Delivery {
        try await toolExecutor.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID,
            messageID: messageID
        )
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await toolExecutor.drainCoordinatorSharedChatMessages(rootSessionID: rootSessionID)
    }

    public func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        await toolExecutor.sharedChatTranscriptMessages(rootSessionID: rootSessionID)
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        await toolExecutor.updateBorrowedSubAgentToolExecutor(executor)
    }

    public func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async {
        await toolExecutor.updateSharedChatMessageAvailableHandler(handler)
    }

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String? = nil
    ) async {
        await toolExecutor.updateToolProviders(providers, sessionID: sessionID)
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        await toolExecutor.subAgentSnapshots()
    }

    public func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {
        await toolExecutor.updateSubAgentToolEventHandler(handler)
    }
}
