//
//  AgentRuntimeBackend.swift
//  ZenCODE
//
//  Contract of a runtime backend and its default implementations.
//

import Foundation

public protocol AgentRuntimeBackend: Actor {
    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func updateSessionOptions(
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async

    func closeSubAgent(id: String) async -> Bool

    func interruptSubAgents(rootSessionID: String) async -> Int

    /// Terminates every running `local.exec` background job owned by this
    /// backend without waiting for exit. Returns how many jobs were still
    /// running. Backends without a direct-tool executor may ignore it.
    func interruptBackgroundJobs() async -> Int

    func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async

    /// Installs the wake-up used by shared-chat renderers. The callback carries
    /// the root room whose bounded transcript changed.
    func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async

    /// Installs the presentation-only lifecycle sink for tools executed by
    /// delegated descendants. Backends without delegation may ignore it.
    func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async

    /// Installs the source of the coordinator's response-language section,
    /// keyed by root session, that delegated agents receive in their system
    /// prompt. Backends without delegation may ignore it.
    func updateSubAgentResponseLanguageSectionProvider(
        _ provider: DirectSubAgentResponseLanguageSectionProvider?
    ) async

    func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String?
    ) async

    func closeSession(id: String) async
    func shutdown() async

    func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult?

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String

    func activeToolDescriptors() async -> [DirectToolDescriptor]
    func activeToolDescriptors(sessionID: String?) async -> [DirectToolDescriptor]
    /// The tool descriptors of `sessionID` already known, read without
    /// starting any tool discovery: a feature's `--list-tools`, or the consent
    /// it can ask for, never runs. For presentation only, such as
    /// ``DirectSubAgentRuntime/transcript(agentID:rootSessionID:)``: a feature
    /// that discovers its tools at runtime contributes the tools already
    /// discovered, or only its declared ones. The default implementation
    /// returns ``activeToolDescriptors(sessionID:)``; a backend whose
    /// descriptors can start a discovery overrides it.
    func knownToolDescriptors(sessionID: String?) async -> [DirectToolDescriptor]

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot]
    func subAgentSnapshotEvents(rootSessionID: String) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>
    /// The live transcript of the delegated agent `agentID` of the root
    /// session `rootSessionID` (see
    /// ``DirectSubAgentRuntime/transcript(agentID:rootSessionID:)``), read
    /// without keeping any state. `nil` when the agent is unknown, belongs to
    /// another root session, its backend was shut down, or the backend has no
    /// sub-agent runtime (the default).
    func subAgentTranscript(
        agentID: String,
        rootSessionID: String
    ) async -> ChatSubAgentTranscript?

    func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant]
    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery
    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID
    ) async throws -> AgentSharedChat.Delivery
    func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message]
    /// Read-only access to every retained message in a room transcript. Unlike
    /// ``drainCoordinatorSharedChatMessages(rootSessionID:)``, this never
    /// removes messages from a mailbox: it returns the full bounded transcript
    /// so a rendering surface can display agent-to-agent messages that never
    /// enter the coordinator mailbox.
    func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message]

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot?

    /// Persists the engine KV cache of `sessionID` to `url`. Called ONLY when
    /// the user saves a session explicitly. Backends with an in-process engine
    /// (DS4) write the live state of the session; they never open the model nor
    /// evaluate a prompt for it. The default implementation does nothing.
    func saveEngineCheckpoint(
        sessionID: String,
        to url: URL
    ) async throws -> AgentEngineCheckpointSaveOutcome

    /// Loads the engine KV cache stored at `url` into `sessionID`, and
    /// re-attaches the private replay data of the checkpoint to the restored
    /// messages. Called ONLY when a saved session is loaded. `onEvent` receives
    /// the engine status when the model has to be opened. The default
    /// implementation does nothing.
    func restoreEngineCheckpoint(
        sessionID: String,
        from url: URL,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async -> AgentEngineCheckpointRestoreOutcome

    /// Runtime control of the in-process DS4 engine (`/ds4`): status, power,
    /// directional steering and programming hints for `sessionID`. Values are
    /// never persisted. The default implementation rejects every command with
    /// `AgentDS4ControlError.unavailable`: only the backend of a DS4 model
    /// implements it.
    func ds4Control(
        _ command: AgentDS4ControlCommand,
        sessionID: String
    ) async throws -> AgentDS4ControlResult
}

extension AgentRuntimeBackend {
    public func ds4Control(
        _: AgentDS4ControlCommand,
        sessionID _: String
    ) async throws -> AgentDS4ControlResult {
        throw AgentDS4ControlError.unavailable
    }

    public func saveEngineCheckpoint(
        sessionID _: String,
        to _: URL
    ) async throws -> AgentEngineCheckpointSaveOutcome {
        .notApplicable
    }

    public func restoreEngineCheckpoint(
        sessionID _: String,
        from _: URL,
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async -> AgentEngineCheckpointRestoreOutcome {
        .notApplicable
    }

    public func activeToolDescriptors(
        sessionID _: String?
    ) async -> [DirectToolDescriptor] {
        await activeToolDescriptors()
    }

    public func knownToolDescriptors(
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        await activeToolDescriptors(sessionID: sessionID)
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {}

    public func closeSubAgent(id: String) async -> Bool {
        false
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        0
    }

    public func interruptBackgroundJobs() async -> Int {
        0
    }

    public func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {}

    public func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) async {}

    public func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {}

    public func updateSubAgentResponseLanguageSectionProvider(
        _ provider: DirectSubAgentResponseLanguageSectionProvider?
    ) async {}

    public func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID _: String?
    ) async {}

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    public func sharedChatParticipants(rootSessionID _: String) async -> [AgentSharedChat.Participant] {
        []
    }

    public func sendSharedChatMessage(
        text _: String,
        destination _: AgentSharedChat.Destination,
        rootSessionID _: String
    ) async throws -> AgentSharedChat.Delivery {
        throw AgentSharedChat.Error.unavailable
    }

    /// Fail-closed compatibility bridge for backends that predate surface
    /// correlation. Legacy calls remain source-compatible through the overload
    /// above, but a correlated caller must never publish a different UUID and
    /// silently lose its response route. Backends that support correlated
    /// delivery must implement this requirement explicitly.
    public func sendSharedChatMessage(
        text _: String,
        destination _: AgentSharedChat.Destination,
        rootSessionID _: String,
        messageID _: UUID
    ) async throws -> AgentSharedChat.Delivery {
        throw AgentSharedChat.Error.unavailable
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID _: String
    ) async -> [AgentSharedChat.Message] {
        []
    }

    public func sharedChatTranscriptMessages(
        rootSessionID _: String
    ) async -> [AgentSharedChat.Message] {
        []
    }

    public func compactSession(
        id _: String,
        force _: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        nil
    }

    public func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }
}

extension AgentRuntimeBackend {
    public func subAgentSnapshotEvents(rootSessionID: String) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]> {
        AsyncStream { $0.finish() }
    }

    public func subAgentTranscript(
        agentID _: String,
        rootSessionID _: String
    ) async -> ChatSubAgentTranscript? {
        nil
    }
}
