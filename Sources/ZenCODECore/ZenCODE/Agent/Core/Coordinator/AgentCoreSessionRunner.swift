//
//  AgentCoreSessionRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization
import ToolCore

/// One-shot barrier between creating a prompt task and publishing it in the
/// runner's cancellation registry.
///
/// `Task.yield()` would merely hint to the executor and cannot establish an
/// ordering edge. `wait()` intentionally does not react to cancellation: a
/// task cancelled while parked must remain parked until `open()` follows its
/// registration, so its finalisation cannot clear an as-yet-unregistered ID.
private final class AgentCorePromptTaskRegistrationGate: Sendable {
    private struct State {
        var isOpen = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isOpen else {
                    return true
                }
                state.waiter = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.isOpen else {
                return nil
            }
            state.isOpen = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

public actor AgentCoreSessionRunner {
    public static var isAvailable: Bool {
        true
    }

    /// Thrown internally when a backend creation is fenced out by a concurrent
    /// reset or shutdown, so `ensureBackend` retries instead of installing a
    /// backend that no longer belongs to the current runtime generation.
    private struct BackendInvalidatedError: Error {}

    /// Identifies one incarnation of a session. Every `createSession` starts a
    /// new generation and every close/reset drops it, so work that started
    /// before the change cannot cache or restore state afterwards.
    private struct SessionGeneration: Hashable {
        let rawValue: UInt64
    }

    private var backend: AgentCoreBackend?
    /// Single-flight guard: concurrent `ensureBackend` callers join this task
    /// instead of each building their own `AgentCoreBackend`.
    private var backendPreparation: Task<AgentCoreBackend, Error>?
    /// Bumped by every reset/shutdown so an in-flight backend creation that
    /// started earlier is discarded instead of overwriting newer state.
    private var backendGeneration: UInt64 = 0
    /// Bumped only by shutdown (never by an ordinary backend reset). Work that
    /// entered before a shutdown compares against it and gives up instead of
    /// building a fresh backend for a runtime nobody is driving anymore.
    private var shutdownGeneration: UInt64 = 0
    private var sessionGenerations: [String: SessionGeneration] = [:]
    private var nextSessionGenerationValue: UInt64 = 1
    private var activeRuntimeConfiguration: AgentCoreSessionConfiguration?
    private var sessions: [String: AgentCoreSessionConfiguration] = [:]
    private var lastKnownSessionSnapshots: [String: AgentRuntimeSessionSnapshot] = [:]
    /// Session-scoped, mutable prompt-skill providers. Owned here so changing
    /// the skill selection updates only this snapshot and never the system
    /// prompt, allowlist, cache key, or remote session identity.
    private var promptSkillProvidersBySessionID: [String: PromptSkillSessionProvider] = [:]
    private var promptTaskRegistry = AgentCorePromptTaskRegistry()
    /// Serializes complete prompt turns per session without coupling unrelated
    /// sessions. It is deliberately outside backend state so a turn remains
    /// ordered across backend creation, recovery, and finalisation.
    private let sessionTurnLease: AgentSessionTurnLease
    /// Core-side owner of coordinator-mailbox monitoring, batching and the
    /// single-flight auto-trigger decision. Built lazily so its message source
    /// can capture this runner weakly and never form a reference cycle.
    private var sharedChatCoordinatorStorage: AgentSharedChatCoordinator?
    /// Actor-isolated catalogue of readable `@mention` handles. Built lazily and
    /// reset alongside the shared-chat coordinator so aliases are never recycled
    /// within a session but start clean on a new one.
    private var sharedChatMentionCatalogStorage: SharedChatMentionCatalog?
    private var promptAuthorizationHandlers: [UUID: AgentToolAuthorizationHandler] = [:]
    /// Maps each prompt ID to the session it belongs to so `authorizeTool`
    /// can route authorization requests to the correct handler.
    private var promptAuthorizationSessionIDs: [UUID: String] = [:]
    /// Session-scoped copy of the same handler, kept alive across turns.
    ///
    /// Delegated sub-agents keep executing tools after the turn that spawned
    /// them has returned, so their consent cannot hang off a turn-scoped entry.
    /// Keying by session (not by turn) also preserves per-origin routing: a
    /// session driven from Telegram keeps asking its own operator there. Only
    /// reset/shutdown clears this map; the per-prompt `defer` must not.
    private var sessionAuthorizationHandlers: [String: AgentToolAuthorizationHandler] = [:]
    private var localExecAccessModeState: AgentLocalExecAccessMode = .standard
    private let defaultToolAuthorizationHandler: AgentToolAuthorizationHandler?
    let mcpRuntime: DirectMCPToolRuntime
    public let taskOrchestrator: SessionTaskOrchestrator
    private let backendFactory: AgentRuntimeBackendFactory?

    public init(
        defaultToolAuthorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil,
        taskOrchestrator: SessionTaskOrchestrator? = nil,
        taskGraphStore: SessionTaskGraphStore? = SessionTaskGraphStore()
    ) {
        self.init(
            defaultToolAuthorizationHandler: defaultToolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory,
            taskOrchestrator: taskOrchestrator,
            taskGraphStore: taskGraphStore,
            sessionTurnLease: AgentSessionTurnLease()
        )
    }

    init(
        defaultToolAuthorizationHandler: AgentToolAuthorizationHandler? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = nil,
        taskOrchestrator: SessionTaskOrchestrator? = nil,
        taskGraphStore: SessionTaskGraphStore? = SessionTaskGraphStore(),
        sessionTurnLease: AgentSessionTurnLease
    ) {
        self.defaultToolAuthorizationHandler = defaultToolAuthorizationHandler
        self.mcpRuntime = mcpRuntime
        self.backendFactory = backendFactory
        self.taskOrchestrator = taskOrchestrator
            ?? SessionTaskOrchestrator(store: taskGraphStore)
        self.sessionTurnLease = sessionTurnLease
    }

    func localExecAccessMode() -> AgentLocalExecAccessMode {
        localExecAccessModeState
    }

    @discardableResult
    func toggleLocalExecAccessMode() -> AgentLocalExecAccessMode {
        localExecAccessModeState = localExecAccessModeState.next
        return localExecAccessModeState
    }

    func resetLocalExecAccessMode() {
        localExecAccessModeState = .standard
    }

    private func createBackendSession(
        _ backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration
    ) async {
        await backend.createSession(
            id: configuration.sessionID,
            cwd: configuration.workingDirectoryPath,
            systemPrompt: configuration.systemPrompt,
            dynamicContext: configuration.dynamicContext,
            history: configuration.history,
            cacheKey: configuration.cacheKey,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    public func createSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        try await taskOrchestrator.registerSession(
            id: configuration.sessionID,
            workingDirectory: URL(fileURLWithPath: configuration.workingDirectoryPath)
        )
        _ = ensurePromptSkillProvider(sessionID: configuration.sessionID)
        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        await createBackendSession(backend, configuration: configuration)
        try verifyBackendGeneration(generation)
        sessions[configuration.sessionID] = configuration
        beginSessionGeneration(for: configuration.sessionID)
        ZenLogger.debug(
            .viewModelRuntime,
            "agent core session runner created session id=\(configuration.sessionID) history=\(configuration.history.count) tools=\(configuration.allowedToolNames?.count ?? 0)."
        )
    }

    public func updateSessionOptions(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        await backend.updateSessionOptions(
            id: configuration.sessionID,
            systemPrompt: configuration.systemPrompt,
            dynamicContext: configuration.dynamicContext,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
        try verifyBackendGeneration(generation)
        sessions[configuration.sessionID] = configuration
    }

    /// Updates only the session-scoped prompt-skill selection. This mutates the
    /// provider snapshot in place and never changes the system prompt,
    /// allowlist, cache key, history, or remote session identity, so the
    /// KV-cache prefix and any remote continuation stay valid across selection
    /// changes.
    public func updatePromptSkillSelection(
        _ skills: [PromptSkill],
        sessionID: String
    ) async {
        let provider = ensurePromptSkillProvider(sessionID: sessionID)
        await provider.update(skills)
    }

    private func ensurePromptSkillProvider(sessionID: String) -> PromptSkillSessionProvider {
        if let existing = promptSkillProvidersBySessionID[sessionID] {
            return existing
        }
        let provider = PromptSkillSessionProvider()
        promptSkillProvidersBySessionID[sessionID] = provider
        return provider
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        let modelID = try await backend.preloadModel(onEvent: onEvent)
        try verifyBackendGeneration(generation)
        return modelID
    }

    public func preloadModel(
        configuration: AgentCoreSessionConfiguration
    ) -> AsyncThrowingStream<DirectAgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DirectAgentEvent, Error>.makeStream()
        let task = Task(name: "Agent model preload", priority: .userInitiated) {
            #if os(macOS)
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated],
                reason: "Agent model load"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            #endif
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
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        try await sessionTurnLease.withLease(sessionID: configuration.sessionID) { [self] in
            try await self.sendPromptUsingLease(
                configuration: configuration,
                prompt: prompt,
                attachments: attachments,
                authorizeTool: authorizeTool,
                onToolWillExecute: onToolWillExecute,
                borrowedSubAgentToolExecutor: borrowedSubAgentToolExecutor,
                toolProviders: toolProviders,
                onEvent: onEvent
            )
        }
    }

    private func sendPromptUsingLease(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = [],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let promptID = UUID()
        if let authorizationHandler = authorizeTool ?? defaultToolAuthorizationHandler {
            promptAuthorizationHandlers[promptID] = authorizationHandler
            promptAuthorizationSessionIDs[promptID] = configuration.sessionID
            // Survives the turn on purpose: delegated work started here can ask
            // for consent long after this prompt completed.
            sessionAuthorizationHandlers[configuration.sessionID] = authorizationHandler
        }
        defer {
            promptAuthorizationHandlers.removeValue(forKey: promptID)
            promptAuthorizationSessionIDs.removeValue(forKey: promptID)
        }

        let backend = try await ensureBackend(configuration: configuration)
        let generation = backendGeneration
        await backend.updateBorrowedSubAgentToolExecutor(
            borrowedSubAgentToolExecutor
        )
        try verifyBackendGeneration(generation)
        let ownedSkillProvider = promptSkillProvidersBySessionID[configuration.sessionID]?.asToolProvider()
        let nonSkillProviders = toolProviders.filter { provider in
            !provider.tools.contains { PromptSkillToolProvider.toolNames.contains($0.name) }
        }
        let effectiveToolProviders = (ownedSkillProvider.map { [$0] } ?? []) + nonSkillProviders
        await backend.updateToolProviders(
            effectiveToolProviders,
            sessionID: configuration.sessionID
        )
        try verifyBackendGeneration(generation)
        try await ensureSession(configuration: configuration)
        try verifyBackendGeneration(generation)
        // Capture the session incarnation only after the session exists: a later
        // close/reset/rebuild drops this generation and fences the turn's
        // snapshot cache and backend restore.
        let sessionGeneration = currentSessionGeneration(for: configuration.sessionID)
        let initialSnapshot = await backend.snapshotSession(id: configuration.sessionID)
            ?? AgentRuntimeSessionSnapshot(configuration: configuration)
        try verifyBackendGeneration(generation)
        let turnRecorder = AgentCorePromptTurnRecorder(
            initialSnapshot: initialSnapshot,
            prompt: prompt,
            attachments: attachments
        )
        // Every turn — operator, replayed, or synthetic — marks the room busy
        // for the Core auto-trigger, so a shared-chat message can never open a
        // second concurrent prompt behind a consumer's back. The prompt is
        // handed over as well: it is what binds a synthetic turn to the claim
        // it consumes, so no unrelated turn can release that claim when it ends.
        let chatCoordinator = sharedChatCoordinator()
        let chatTurn = await chatCoordinator.noteTurnStarted(
            roomID: configuration.sessionID,
            prompt: prompt
        )

        // Bounded and best-effort: this returns nil on timeout, failure, or an
        // empty graph, and the turn then proceeds with a request that is
        // byte-identical to one sent with memory switched off.
        let memoryBlock = await MemoryTurnCoordinator.shared.memoryBlock(
            sessionID: configuration.sessionID,
            workspaceRootURL: configuration.workingDirectory,
            prompt: prompt
        )

        do {
            let response = try await AgentToolAuthorizationContext.$turnID.withValue(promptID) {
                // Nested inside the existing turn-scoped binding, and around
                // the same call, so the block reaches request assembly through
                // the actor hop exactly the way `turnID` already reaches tool
                // executors. It is scoped to this one `sendPrompt`, so nothing
                // that outlives the turn can observe it.
                try await MemoryTurnContext.$currentTurnMemoryBlock.withValue(memoryBlock) {
                    try await backend.sendPrompt(
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
                }
            }
            try verifyBackendGeneration(generation)
            await finalizeTurn(
                outcome: .completed,
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                sessionGeneration: sessionGeneration,
                backendGeneration: generation,
                onEvent: onEvent
            )
            await chatCoordinator.noteTurnEnded(chatTurn)
            return response
        } catch is CancellationError {
            await finalizeTurn(
                outcome: .cancelled,
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                sessionGeneration: sessionGeneration,
                backendGeneration: generation,
                onEvent: onEvent
            )
            // A cancelled synthetic turn must still release the room, otherwise
            // later shared-chat messages would never start a turn again.
            await chatCoordinator.noteTurnEnded(chatTurn)
            throw CancellationError()
        } catch {
            await finalizeTurn(
                outcome: .failed(message: error.localizedDescription),
                backend: backend,
                configuration: configuration,
                recorder: turnRecorder,
                sessionGeneration: sessionGeneration,
                backendGeneration: generation,
                onEvent: onEvent
            )
            await chatCoordinator.noteTurnEnded(chatTurn)
            throw error
        }
    }

    /// Shared turn-finalization: snapshot, restore, and turn-ended event.
    private func finalizeTurn(
        outcome: DirectAgentTurnOutcome,
        backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration,
        recorder: AgentCorePromptTurnRecorder,
        sessionGeneration: SessionGeneration?,
        backendGeneration: UInt64,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        guard self.backendGeneration == backendGeneration else {
            return
        }
        let recovery = await recoveredSessionSnapshot(
            backend: backend,
            configuration: configuration,
            recorder: recorder,
            sessionGeneration: sessionGeneration
        )
        guard self.backendGeneration == backendGeneration else {
            return
        }
        await restoreSessionIfNeeded(
            recovery,
            backend: backend,
            baseConfiguration: configuration,
            sessionGeneration: sessionGeneration
        )
        guard self.backendGeneration == backendGeneration else {
            return
        }
        await onEvent(.sessionSnapshot(recovery.snapshot))
        await onEvent(.turnEnded(outcome))
    }

    public func closeSubAgent(id: String) async -> Bool {
        guard let backend else { return false }
        return await backend.closeSubAgent(id: id)
    }

    public func interruptSubAgents(rootSessionID: String) async -> Int {
        guard let backend else { return 0 }
        return await backend.interruptSubAgents(rootSessionID: rootSessionID)
    }

    public func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        guard let backend else {
            return []
        }
        return await backend.subAgentSnapshots()
    }

    public func sharedChatParticipants(
        rootSessionID: String
    ) async -> [AgentSharedChat.Participant] {
        guard let backend else { return [] }
        return await backend.sharedChatParticipants(rootSessionID: rootSessionID)
    }

    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        guard let backend else { throw AgentSharedChat.Error.unavailable }
        return try await backend.sendSharedChatMessage(
            text: text,
            destination: destination,
            rootSessionID: rootSessionID
        )
    }

    public func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        guard let backend else { return [] }
        return await backend.drainCoordinatorSharedChatMessages(rootSessionID: rootSessionID)
    }

    public func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        guard let backend else { return [] }
        return await backend.sharedChatTranscriptMessages(rootSessionID: rootSessionID)
    }

    /// The Core auto-trigger. It owns mailbox monitoring, batching and the
    /// idle/busy decision; rendering surfaces are consumers, never owners.
    func sharedChatCoordinator() -> AgentSharedChatCoordinator {
        if let sharedChatCoordinatorStorage {
            return sharedChatCoordinatorStorage
        }
        let coordinator = AgentSharedChatCoordinator(
            source: AgentSharedChatCoordinator.Source(
                drainCoordinatorMessages: { [weak self] roomID in
                    await self?.drainCoordinatorSharedChatMessages(rootSessionID: roomID) ?? []
                },
                participants: { [weak self] roomID in
                    await self?.sharedChatParticipants(rootSessionID: roomID) ?? []
                },
                allRoomMessages: { [weak self] roomID in
                    await self?.sharedChatTranscriptMessages(rootSessionID: roomID) ?? []
                }
            )
        )
        sharedChatCoordinatorStorage = coordinator
        return coordinator
    }

    /// The actor-isolated mention catalogue for this session. Handles are
    /// readable aliases derived from participant names; routing is always by
    /// stable participant id.
    func sharedChatMentionCatalog() -> SharedChatMentionCatalog {
        if let sharedChatMentionCatalogStorage {
            return sharedChatMentionCatalogStorage
        }
        let catalog = SharedChatMentionCatalog()
        sharedChatMentionCatalogStorage = catalog
        return catalog
    }

    /// Returns a handle → participant-id map for the current room roster. Used
    /// by the autocomplete list (display) and the mention parser (routing).
    public func sharedChatMentionHandles(
        rootSessionID: String
    ) async -> [String: String] {
        await sharedChatMentionRoster(rootSessionID: rootSessionID).handleMap
    }

    /// Returns participants and readable handles from one roster snapshot, so a
    /// join/leave between separate backend reads cannot mismatch labels and IDs.
    public func sharedChatMentionRoster(
        rootSessionID: String
    ) async -> (
        participants: [AgentSharedChat.Participant],
        handleMap: [String: String]
    ) {
        let participants = await sharedChatParticipants(rootSessionID: rootSessionID)
        let handleMap = await sharedChatMentionCatalog().handleMap(for: participants)
        return (participants, handleMap)
    }

    /// Resolves a readable mention handle to its stable participant id, or nil
    /// when no live mapping exists.
    public func resolveSharedChatMentionHandle(
        _ handle: String
    ) async -> String? {
        await sharedChatMentionCatalog().participantID(forHandle: handle)
    }

    /// Subscribes to live shared-chat coordination.
    ///
    /// Every consumer — terminal UI, ACP, or a headless driver — receives the
    /// same semantics: `messages` for rendering, `participantsChanged` for
    /// roster refreshes, and `autoTrigger` for the one synthetic turn the Core
    /// authorises at a time. The returned observation is the consumer's
    /// identity: resolve each trigger with
    /// ``resolveSharedChatAutoTrigger(id:observation:resolution:)`` and start a
    /// synthetic prompt only when it returns `acquired`; report consumer-side
    /// activity with ``setSharedChatConsumerBusy(_:observation:)``. Detaching
    /// releases exactly this consumer's busy state and claimed turn.
    public func attachSharedChatObservation(
        rootSessionID: String
    ) async -> AgentSharedChatCoordinator.Observation {
        let coordinator = sharedChatCoordinator()
        if let backend {
            await backend.updateSharedChatMessageAvailableHandler { roomID in
                Task(name: "ZenCODE.shared-chat.transcript-wake") {
                    await coordinator.requestPoll(roomID: roomID)
                }
            }
        }
        return await coordinator.observeSubscription(roomID: rootSessionID)
    }

    /// Detaches one observer without ending coordination for the room's other
    /// consumers. Full room stop remains a session-teardown operation.
    public func detachSharedChatObservation(
        _ observation: AgentSharedChatCoordinator.Observation
    ) async {
        await sharedChatCoordinatorStorage?.detach(observation)
    }

    /// Ends coordination for one room during session teardown, terminating all
    /// its event streams. Messages that never reached a synthetic turn stay
    /// queued for a future session consumer.
    public func stopSharedChatObservation(rootSessionID: String) async {
        await sharedChatCoordinatorStorage?.stop(roomID: rootSessionID)
    }

    /// Declares consumer-side activity (running or queued prompts) for one
    /// observer, so the Core never authorises a synthetic turn concurrently
    /// with that consumer's work. Another observer reporting itself idle can
    /// never clear this declaration.
    public func setSharedChatConsumerBusy(
        _ isBusy: Bool,
        observation: AgentSharedChatCoordinator.Observation
    ) async {
        await sharedChatCoordinator().setConsumerBusy(isBusy, observation: observation)
    }

    /// Atomically tries to take a published auto-trigger for one observer. The
    /// same trigger can reach multiple observers of a room; only one `started`
    /// resolution returns ``AgentSharedChatAutoTriggerClaimResult/acquired``,
    /// and only its owner can later release it. Consumers must treat
    /// `notAcquired` as stale and must not start a generation.
    @discardableResult
    public func resolveSharedChatAutoTrigger(
        id: UUID,
        observation: AgentSharedChatCoordinator.Observation,
        resolution: AgentSharedChatAutoTriggerResolution
    ) async -> AgentSharedChatAutoTriggerClaimResult {
        await sharedChatCoordinatorStorage?.resolveAutoTrigger(
            id: id,
            observation: observation,
            resolution: resolution
        ) ?? .notAcquired
    }

    /// Returns an unclaimed trigger of a retired room to the queue. A consumer
    /// that already rebound to another session has no observation left there,
    /// but must still release the batch it will never answer.
    public func declineSharedChatAutoTrigger(
        id: UUID,
        rootSessionID: String
    ) async {
        await sharedChatCoordinatorStorage?.declineAutoTrigger(
            id: id,
            roomID: rootSessionID
        )
    }

    /// Returns the descriptors currently active for one session. This lookup is
    /// intended for best-effort replay presentation; live calls already carry
    /// the descriptor snapshot selected for their model round.
    public func activeToolDescriptors(
        sessionID: String
    ) async -> [DirectToolDescriptor] {
        guard let backend else {
            return []
        }
        return await backend.activeToolDescriptors(sessionID: sessionID)
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
            dynamicContext: configuration.dynamicContext,
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
        let generation = backendGeneration
        let currentSnapshot = await backend?.snapshotSession(id: sessionID)
            ?? lastKnownSessionSnapshots[sessionID]
            ?? AgentRuntimeSessionSnapshot(configuration: baseConfiguration)
        guard generation == backendGeneration else {
            return false
        }
        let replacement = currentSnapshot.replacingHistory(history)
        let replacementConfiguration = baseConfiguration.replacingRuntimeState(
            with: replacement
        )

        sessions[sessionID] = replacementConfiguration
        lastKnownSessionSnapshots[sessionID] = replacement
        if let backend {
            await backend.clearSession(id: sessionID)
            guard generation == backendGeneration else {
                return false
            }
            await backend.createSession(
                id: replacement.sessionID,
                cwd: replacement.workingDirectoryPath,
                systemPrompt: replacement.systemPrompt,
                dynamicContext: replacement.dynamicContext,
                history: replacement.history,
                cacheKey: replacement.cacheKey,
                allowedToolNames: replacement.allowedToolNames,
                thinkingSelection: replacement.thinkingSelection,
                preserveThinking: replacement.preserveThinking
            )
            guard generation == backendGeneration else {
                return false
            }
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

        let generation = backendGeneration
        let result: AgentRuntimeSessionCompactionResult?
        if let backendResult = await backend?.compactSession(
            id: sessionID,
            force: force,
            maxTokensOverride: maxTokensOverride
        ) {
            try verifyBackendGeneration(generation)
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

        try verifyBackendGeneration(generation)
        cacheCompactedSessionSnapshot(result.snapshot)
        return result
    }

    /// Shared session-restore entry point used by persisted TUI and ACP
    /// sessions to recreate their runtime state from the saved configuration.
    public func restoreSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws {
        try await createSession(configuration: configuration)
    }


    public func streamPrompt(
        _ prompt: String,
        configuration: AgentCoreSessionConfiguration,
        attachments: [AgentRuntimeAttachment] = [],
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)? = nil,
        borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor? = nil,
        toolProviders: [AgentToolProvider] = []
    ) -> AsyncThrowingStream<DirectAgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<DirectAgentEvent, Error>.makeStream()
        let promptID = UUID()
        let outcomeTracker = AgentCorePromptOutcomeTracker()
        let registrationGate = AgentCorePromptTaskRegistrationGate()
        let task = Task(name: "Agent prompt stream", priority: .userInitiated) {
            await registrationGate.wait()
            #if os(macOS)
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Agent generation"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }
            #endif
            do {
                try Task.checkCancellation()
                _ = try await sendPrompt(
                    configuration: configuration,
                    prompt: prompt,
                    attachments: attachments,
                    authorizeTool: authorizeTool,
                    onToolWillExecute: onToolWillExecute,
                    borrowedSubAgentToolExecutor: borrowedSubAgentToolExecutor,
                    toolProviders: toolProviders
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
        registrationGate.open()
        continuation.onTermination = { _ in
            task.cancel()
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
        } else if let error, await outcomeTracker.shouldEmitFallback() {
            continuation.yield(.turnEnded(.failed(message: error.localizedDescription)))
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
    }

    public func cancelPrompt(sessionID: String) async {
        promptTaskRegistry.cancelAll(for: sessionID)
    }

    /// Rebuilds transient model/session state while preserving the authoritative
    /// task graph for the same session identity.
    public func rebuildSession(id sessionID: String) async {
        promptTaskRegistry.cancelAll(for: sessionID)
        await waitForPromptTasks(for: sessionID)
        invalidateSessionGeneration(for: sessionID)
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
        // The rebuilt session keeps its identity but starts a new conversation,
        // so it must not inherit paused recall from the history being dropped.
        await MemoryTurnCoordinator.shared.discard(sessionID: sessionID)
        // The transient bus lives inside the backend tree: release an
        // unresolved synthetic batch so it is re-offered instead of lost, while
        // keeping live observers attached across the rebuild. The room stays
        // fenced until the clear below has run, so no poll woken in between can
        // drain the retiring bus into the rebuilt session.
        let chatReset = await sharedChatCoordinatorStorage?.beginReset(roomID: sessionID)
        await backend?.clearSession(id: sessionID)
        if let chatReset {
            await sharedChatCoordinatorStorage?.endReset(chatReset)
        }
        // A rebuilt session is a fresh conversation: readable mention aliases
        // start clean so they are never inherited from the dropped roster.
        await sharedChatMentionCatalogStorage?.reset()
    }

    /// Discards a logical session, including its persisted task graph.
    public func resetSession(id sessionID: String? = nil) async {
        do {
            try await resetSessionThrowing(id: sessionID)
        } catch {
            ZenLogger.error(
                .viewModelRuntime,
                "agent core session runner could not discard task graph: \(error.localizedDescription)"
            )
        }
    }

    /// Throwing counterpart to ``resetSession(id:)`` for callers that need to
    /// surface a checkpoint-deletion failure instead of treating teardown as
    /// best-effort. The original non-throwing API remains available.
    public func resetSessionThrowing(id sessionID: String? = nil) async throws {
        if let sessionID {
            _ = await interruptSubAgents(rootSessionID: sessionID)
            await rebuildSession(id: sessionID)
            try await taskOrchestrator.discardSession(id: sessionID)
            return
        }

        await cancelAllPromptTasksAndWait()
        promptAuthorizationHandlers.removeAll()
        promptAuthorizationSessionIDs.removeAll()
        sessionAuthorizationHandlers.removeAll()
        sessionGenerations.removeAll()

        let taskSessionIDs = await taskOrchestrator.registeredSessionIDs()
        let sessionIDs = Array(
            Set(sessions.keys)
                .union(lastKnownSessionSnapshots.keys)
                .union(taskSessionIDs)
        )
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        for sessionID in sessionIDs {
            _ = await interruptSubAgents(rootSessionID: sessionID)
            await MemoryTurnCoordinator.shared.discard(sessionID: sessionID)
            // Same ordering as `rebuildSession`: the room is fenced across the
            // backend clear, never merely before it.
            let chatReset = await sharedChatCoordinatorStorage?.beginReset(roomID: sessionID)
            await backend?.clearSession(id: sessionID)
            if let chatReset {
                await sharedChatCoordinatorStorage?.endReset(chatReset)
            }
            try await taskOrchestrator.discardSession(id: sessionID)
        }
    }

    public func closeSession(id sessionID: String) async {
        do {
            try await closeSessionThrowing(id: sessionID)
        } catch {
            ZenLogger.error(
                .viewModelRuntime,
                "agent core session runner could not flush task graph: \(error.localizedDescription)"
            )
        }
    }

    /// Throwing counterpart to ``closeSession(id:)`` for callers that need to
    /// report persistence failures before a session is torn down.
    public func closeSessionThrowing(id sessionID: String) async throws {
        promptTaskRegistry.cancelAll(for: sessionID)
        // Drop the incarnation before any suspension so a prompt that is still
        // winding down cannot cache or restore this session afterwards.
        invalidateSessionGeneration(for: sessionID)
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
        _ = await interruptSubAgents(rootSessionID: sessionID)
        // Wait for every cancelled prompt task to finish its finalisation before
        // checkpointing. Without this, a prompt winding down can update the task
        // graph after `flush` has already written the checkpoint, losing the
        // update or producing an inconsistent snapshot.
        await waitForPromptTasks(for: sessionID)
        // A recreated session reuses the id, so its recall health belongs to
        // the incarnation that owned the conversation. Drop it before the
        // throwing checkpoint flush so a failed close cannot strand a pause.
        await MemoryTurnCoordinator.shared.discard(sessionID: sessionID)
        try await taskOrchestrator.flush(sessionID: sessionID)
        promptSkillProvidersBySessionID.removeValue(forKey: sessionID)
        // Terminate coordination for this room so a suspended observer resumes
        // instead of waiting forever on a closed session.
        await sharedChatCoordinatorStorage?.stop(roomID: sessionID)
        await backend?.closeSession(id: sessionID)
        // Re-drop after the suspensions above: a prompt finalization that raced
        // this close may have re-inserted state before its generation check.
        sessions.removeValue(forKey: sessionID)
        lastKnownSessionSnapshots.removeValue(forKey: sessionID)
    }

    public func shutdown() async {
        // Latch before the first suspension: an `ensureBackend` caller that is
        // already parked in the single-flight preparation observes this and
        // gives up, instead of looping and building a fresh backend for a
        // runtime that is being torn down. An ordinary backend reset (model or
        // agent switch) deliberately does *not* latch it, so those callers keep
        // their retry-and-rebuild behaviour.
        shutdownGeneration &+= 1
        await shutdownBackendKeepingExternalTools()
        await mcpRuntime.shutdown()
    }

    /// Shuts down the model backend and all session state while keeping the
    /// connected external MCP servers alive. Use this for backend resets such as model or
    /// agent switching, where tearing down MCP connections would force the
    /// user to grant external-tool consents again.
    public func shutdownBackendKeepingExternalTools() async {
        do {
            try await shutdownBackendKeepingExternalToolsThrowing()
        } catch {
            ZenLogger.error(
                .viewModelRuntime,
                "agent core session runner could not flush task graphs: \(error.localizedDescription)"
            )
        }
    }

    /// Throwing counterpart to ``shutdownBackendKeepingExternalTools()``. It
    /// retains the compatibility wrapper while making a failed graph flush
    /// observable to lifecycle owners.
    public func shutdownBackendKeepingExternalToolsThrowing() async throws {
        await cancelAllPromptTasksAndWait()
        promptAuthorizationHandlers.removeAll()
        promptAuthorizationSessionIDs.removeAll()
        sessionAuthorizationHandlers.removeAll()
        // Fence in-flight backend creation and session work before suspending.
        backendGeneration &+= 1
        backendPreparation?.cancel()
        backendPreparation = nil
        sessionGenerations.removeAll()
        try await taskOrchestrator.flush()
        // Terminate every task-graph event observer so suspended `events(...)`
        // consumers resume instead of waiting forever after shutdown.
        await taskOrchestrator.finishEventStreams()
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        promptSkillProvidersBySessionID.removeAll()
        // The runtime tree that produced the transient transcript is gone, so
        // finish every observer and drop the parked batches with it.
        await sharedChatCoordinatorStorage?.stopAll()
        await sharedChatMentionCatalogStorage?.reset()
        activeRuntimeConfiguration = nil
        let backendToShutdown = backend
        backend = nil
        await backendToShutdown?.shutdown()
    }

    private func waitForPromptTasks(for sessionID: String) async {
        let tasks = promptTaskRegistry.tasks(for: sessionID)
        for task in tasks {
            await task.value
        }
    }

    private func cancelAllPromptTasksAndWait() async {
        promptTaskRegistry.cancelAllTasks()
        let tasks = promptTaskRegistry.activeTasks
        for task in tasks {
            await task.value
        }
    }

    private func clearActivePromptTask(id promptID: UUID) {
        promptTaskRegistry.clear(id: promptID)
        promptAuthorizationHandlers.removeValue(forKey: promptID)
        promptAuthorizationSessionIDs.removeValue(forKey: promptID)
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

    /// Returns the runner-owned backend, creating it at most once even when
    /// several prompts, preloads, or session updates race: concurrent callers
    /// join the in-flight creation instead of starting a second one.
    private func ensureBackend(
        configuration: AgentCoreSessionConfiguration
    ) async throws -> AgentCoreBackend {
        // Snapshot the shutdown epoch on entry. A `reset` (model or agent
        // switch) is a legitimate reason to loop and rebuild; a `shutdown` is
        // not, so a caller that was suspended across one must fail instead of
        // resurrecting a backend behind the closed runtime.
        let entryShutdownGeneration = shutdownGeneration

        func ensureNotShutDownSinceEntry() throws {
            guard shutdownGeneration == entryShutdownGeneration else {
                throw BackendInvalidatedError()
            }
        }

        while true {
            try ensureNotShutDownSinceEntry()
            if let preparation = backendPreparation {
                // Single-flight: wait for the in-flight creation, then
                // re-evaluate because a reset may have happened meanwhile.
                _ = try? await preparation.value
                if backendPreparation == preparation {
                    backendPreparation = nil
                }
                try ensureNotShutDownSinceEntry()
                continue
            }

            if let activeRuntimeConfiguration,
               !activeRuntimeConfiguration.matchesRuntime(configuration) {
                await resetBackend()
                try ensureNotShutDownSinceEntry()
                continue
            }

            if let backend {
                return backend
            }

            let generation = backendGeneration
            let preparation = Task(name: "Agent backend preparation") { [weak self] () throws -> AgentCoreBackend in
                guard let self else {
                    throw BackendInvalidatedError()
                }
                return try await self.makeBackend(
                    configuration: configuration,
                    generation: generation
                )
            }
            backendPreparation = preparation
            do {
                let backend = try await preparation.value
                if backendPreparation == preparation {
                    backendPreparation = nil
                }
                try ensureNotShutDownSinceEntry()
                return backend
            } catch {
                if backendPreparation == preparation {
                    backendPreparation = nil
                }
                // A shutdown fences this caller for good; only a reset earns a
                // retry against the current generation.
                try ensureNotShutDownSinceEntry()
                if error is BackendInvalidatedError {
                    continue
                }
                throw error
            }
        }
    }

    private func makeBackend(
        configuration: AgentCoreSessionConfiguration,
        generation: UInt64
    ) async throws -> AgentCoreBackend {
        let runtimeConfiguration = configuration.runtimeConfiguration
            .withToolAuthorizationHandler { request in
                await self.authorizeTool(request)
            }
        let backend = AgentCoreBackend(
            configuration: runtimeConfiguration,
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory
        )
        await backend.installTaskOrchestrator(taskOrchestrator)
        guard generation == backendGeneration else {
            // Reset or shutdown ran while this backend was being prepared:
            // discard the orphan instead of installing stale state.
            await backend.shutdown()
            throw BackendInvalidatedError()
        }
        self.backend = backend
        activeRuntimeConfiguration = configuration
        ZenLogger.debug(
            .viewModelRuntime,
            "agent core session runner initialized model=\(configuration.modelID ?? "default") workingDirectory=\(configuration.workingDirectoryPath)."
        )
        return backend
    }

    private func resetBackend() async {
        backendGeneration &+= 1
        backendPreparation?.cancel()
        backendPreparation = nil
        sessions.removeAll()
        lastKnownSessionSnapshots.removeAll()
        sessionGenerations.removeAll()
        activeRuntimeConfiguration = nil
        let backendToShutdown = backend
        backend = nil
        await backendToShutdown?.shutdown()
    }

    private func verifyBackendGeneration(_ generation: UInt64) throws {
        guard generation == backendGeneration else {
            throw BackendInvalidatedError()
        }
    }

    @discardableResult
    private func beginSessionGeneration(for sessionID: String) -> SessionGeneration {
        let generation = SessionGeneration(rawValue: nextSessionGenerationValue)
        nextSessionGenerationValue &+= 1
        sessionGenerations[sessionID] = generation
        return generation
    }

    private func currentSessionGeneration(for sessionID: String) -> SessionGeneration? {
        sessionGenerations[sessionID]
    }

    private func invalidateSessionGeneration(for sessionID: String) {
        sessionGenerations.removeValue(forKey: sessionID)
    }

    /// `true` while the captured incarnation is still the live one. A closed,
    /// rebuilt, reset, or shut-down session never matches again.
    private func isCurrentSessionGeneration(
        _ generation: SessionGeneration?,
        for sessionID: String
    ) -> Bool {
        guard let generation else {
            return false
        }
        return sessionGenerations[sessionID] == generation
    }

    private func recoveredSessionSnapshot(
        backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration,
        recorder: AgentCorePromptTurnRecorder,
        sessionGeneration: SessionGeneration?
    ) async -> AgentCoreSessionSnapshotRecovery {
        let recordedSnapshot = await recorder.snapshot()
        if let backendSnapshot = await backend.snapshotSession(id: configuration.sessionID),
           backendSnapshot.includesLikelyTurn(from: recordedSnapshot) {
            cacheSessionSnapshot(
                backendSnapshot,
                baseConfiguration: configuration,
                sessionGeneration: sessionGeneration
            )
            return AgentCoreSessionSnapshotRecovery(
                snapshot: backendSnapshot,
                shouldRestoreBackend: false
            )
        }

        cacheSessionSnapshot(
            recordedSnapshot,
            baseConfiguration: configuration,
            sessionGeneration: sessionGeneration
        )
        return AgentCoreSessionSnapshotRecovery(
            snapshot: recordedSnapshot,
            shouldRestoreBackend: isCurrentSessionGeneration(
                sessionGeneration,
                for: configuration.sessionID
            )
        )
    }

    private func restoreSessionIfNeeded(
        _ recovery: AgentCoreSessionSnapshotRecovery,
        backend: AgentCoreBackend,
        baseConfiguration: AgentCoreSessionConfiguration,
        sessionGeneration: SessionGeneration?
    ) async {
        guard recovery.shouldRestoreBackend else {
            return
        }
        // The session may have been closed or rebuilt while the turn was
        // running; recreating it here would resurrect discarded state.
        guard isCurrentSessionGeneration(
            sessionGeneration,
            for: baseConfiguration.sessionID
        ) else {
            return
        }
        let configuration = baseConfiguration.replacingRuntimeState(
            with: recovery.snapshot
        )
        await createBackendSession(backend, configuration: configuration)
    }

    private func cacheSessionSnapshot(
        _ snapshot: AgentRuntimeSessionSnapshot,
        baseConfiguration: AgentCoreSessionConfiguration,
        sessionGeneration: SessionGeneration?
    ) {
        // Never re-add state for a session that was closed, rebuilt, or reset
        // while the turn was still running.
        guard isCurrentSessionGeneration(
            sessionGeneration,
            for: snapshot.sessionID
        ) else {
            return
        }
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
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: maxTokensOverride ?? baseConfiguration.configuredContextWindowLimit,
                maxOutputTokens: baseConfiguration.maxOutputTokens
            ),
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
        // Full access skips prompts for shell commands and for the destructive
        // direct tools alike; otherwise gating deletes while allowing `rm -rf`
        // through local.exec would only push callers toward the shell.
        if localExecAccessModeState == .fullAccess,
           LocalExecPermissionAuthorizer.gatedToolNames.contains(request.toolName) {
            return true
        }

        // Delegated sub-agents are not bound to the turn that spawned them:
        // they call tools from their own private session and keep working after
        // that turn returned, so the turn/session match below can never hold
        // for them. Route on the runtime-minted delegation identity instead,
        // and only when its root session is one this runner actually owns — an
        // unknown root session names no operator, so there is nobody to ask.
        // The handler is still never picked arbitrarily from the Dictionary: it
        // is the one registered for that exact root session, or the runner's
        // default. With neither, the request fails closed like any other.
        if let delegation = request.delegatedIdentity {
            guard isKnownSession(delegation.rootSessionID),
                  let handler = sessionAuthorizationHandlers[delegation.rootSessionID]
                      ?? defaultToolAuthorizationHandler else {
                return false
            }
            let presentedRequest = await delegatedRequestForPresentation(
                request,
                delegation: delegation
            )
            return await handler(presentedRequest)
        }

        // A request must name the exact live turn and session. Never select an
        // arbitrary handler from a Dictionary: concurrent prompts in the same
        // session can have different authorization policies.
        guard let turnID = request.turnID,
              let handler = promptAuthorizationHandlers[turnID],
              let expectedSessionID = promptAuthorizationSessionIDs[turnID],
              request.sessionID == expectedSessionID else {
            return false
        }
        return await handler(request)
    }

    /// A session this runner owns, either because it is still configured or
    /// because a turn of it registered an operator handler. Anything else is
    /// not ours to authorize.
    private func isKnownSession(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil || sessionAuthorizationHandlers[sessionID] != nil
    }

    /// Names the delegated agent in the title so the operator can see *who* is
    /// asking before approving.
    ///
    /// Strictly best-effort: resolution never gates the decision, and a missing
    /// backend, an unknown id, or a blank name falls back to the agent id. Only
    /// `title` changes — `LocalExecPermissionAuthorizer` keys its consent cache
    /// on tool name and command — so remembered approvals stay keyed exactly as
    /// before. The single `await` here reads the backend's sub-agent registry,
    /// which never calls back into this runner, so it cannot stall a
    /// coordinator turn waiting on this actor.
    private func delegatedRequestForPresentation(
        _ request: AgentToolAuthorizationRequest,
        delegation: AgentToolAuthorizationRequest.DelegatedIdentity
    ) async -> AgentToolAuthorizationRequest {
        var label = delegation.agentID
        if let backend {
            let snapshots = await backend.subAgentSnapshots()
            if let name = snapshots.first(where: { $0.id == delegation.agentID })?.name.nilIfBlank {
                label = name
            }
        }
        return request.withTitle("[agent \(label)] \(request.title)")
    }
}
