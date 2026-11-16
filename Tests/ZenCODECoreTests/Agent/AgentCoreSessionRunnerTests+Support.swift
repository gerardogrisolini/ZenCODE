//
//  AgentCoreSessionRunnerTests+Support.swift
//  ZenCODE
//
//  Test doubles shared by the AgentCoreSessionRunner tests: recording
//  authorization actors and capturing or authorization-invoking runtime
//  backends.
//

import Foundation
@testable import ZenCODECore
import Testing

actor AuthorizationRecorder {
    private let decision: Bool
    private var requests: [AgentToolAuthorizationRequest] = []

    init(decision: Bool) {
        self.decision = decision
    }

    func authorize(_ request: AgentToolAuthorizationRequest) -> Bool {
        requests.append(request)
        return decision
    }

    func toolNames() -> [String] {
        requests.map(\.toolName)
    }

    /// Full recorded requests, used to assert presentation-only fields such as
    /// the operator-facing title.
    func recordedRequests() -> [AgentToolAuthorizationRequest] {
        requests
    }
}

final class AuthorizationBackendBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AgentToolAuthorizationRequest] = []
    private var results: [Bool] = []
    private var capturedAuthorizationHandler: AgentToolAuthorizationHandler?

    func makeBackend(
        handler: AgentToolAuthorizationHandler?
    ) -> AuthorizationInvokingBackend {
        lock.lock()
        capturedAuthorizationHandler = handler
        lock.unlock()
        return AuthorizationInvokingBackend(handler: handler, box: self)
    }

    func authorizationHandler() -> AgentToolAuthorizationHandler? {
        lock.lock()
        defer { lock.unlock() }
        return capturedAuthorizationHandler
    }

    func setAuthorizationRequests(_ requests: [AgentToolAuthorizationRequest]) {
        lock.lock()
        self.requests = requests
        lock.unlock()
    }

    func authorizationRequests() -> [AgentToolAuthorizationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func setAuthorizationResults(_ results: [Bool]) {
        lock.lock()
        self.results = results
        lock.unlock()
    }

    func lastAuthorizationResults() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

actor AuthorizationInvokingBackend: AgentRuntimeBackend {
    private let handler: AgentToolAuthorizationHandler?
    private let box: AuthorizationBackendBox
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(handler: AgentToolAuthorizationHandler?, box: AuthorizationBackendBox) {
        self.handler = handler
        self.box = box
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
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
        guard sessions[id] == nil else { return }
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
    func shutdown() async { sessions.removeAll() }
    func preloadModel(onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String {
        "test-model"
    }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        var results: [Bool] = []
        for template in box.authorizationRequests() {
            // Production tool executors create authorization requests while the
            // prompt's TaskLocal turn is active. Rebuild the recorded template
            // here so the fixture exercises the same turn-bound routing.
            // Carry the delegation identity through so a delegated template
            // exercises the delegated routing branch just like production.
            let request = AgentToolAuthorizationRequest(
                sessionID: template.sessionID,
                toolCallID: template.toolCallID,
                toolName: template.toolName,
                title: template.title,
                kind: template.kind,
                command: template.command,
                workingDirectory: template.workingDirectory,
                delegatedIdentity: template.delegatedIdentity
            )
            results.append(await handler?(request) ?? true)
        }
        box.setAuthorizationResults(results)
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

actor SessionRunnerTestGate {
    private struct EnteredWaiter {
        let requiredEntryCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var isOpen = false
    private var entryCount = 0
    private var enteredWaiters: [EnteredWaiter] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered(_ requiredEntryCount: Int = 1) async {
        guard entryCount < requiredEntryCount else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(EnteredWaiter(
                requiredEntryCount: requiredEntryCount,
                continuation: continuation
            ))
        }
    }

    func waitIfClosed() async {
        entryCount += 1
        let readyWaiters = enteredWaiters.filter {
            $0.requiredEntryCount <= entryCount
        }
        enteredWaiters.removeAll {
            $0.requiredEntryCount <= entryCount
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

actor CapturingAgentRuntimeBackend: AgentRuntimeBackend {
    private var updatedSystemPrompt: String?
    private var updatedAllowedToolNames: Set<String>?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var createdHistories: [[AgentRuntimeMessage]] = []
    private var interruptedRoots: [String] = []
    private var interruptedBackgroundJobCounts: [Int] = []
    private var subAgentToolEventHandler: DirectSubAgentToolEventHandler?
    private let promptEvents: [DirectAgentEvent]
    private let sendPromptError: Error?
    private let closeSessionGate: SessionRunnerTestGate?
    private let backgroundJobInterruptCount: Int

    init(
        promptEvents: [DirectAgentEvent] = [],
        sendPromptError: Error? = nil,
        closeSessionGate: SessionRunnerTestGate? = nil,
        backgroundJobInterruptCount: Int = 0
    ) {
        self.promptEvents = promptEvents
        self.sendPromptError = sendPromptError
        self.closeSessionGate = closeSessionGate
        self.backgroundJobInterruptCount = backgroundJobInterruptCount
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
        createdHistories.append(history)
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

    func updateSessionOptions(
        id _: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        updatedSystemPrompt = systemPrompt
        updatedAllowedToolNames = allowedToolNames
    }

    func updateBorrowedSubAgentToolExecutor(
        _: AgentBorrowedToolExecutor?
    ) async {}

    func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {
        subAgentToolEventHandler = handler
    }

    func updateToolProviders(_: [AgentToolProvider]) async {}

    func closeSession(id: String) async {
        await closeSessionGate?.waitIfClosed()
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    func interruptSubAgents(rootSessionID: String) async -> Int {
        interruptedRoots.append(rootSessionID)
        return 0
    }

    func interruptBackgroundJobs() async -> Int {
        interruptedBackgroundJobCounts.append(backgroundJobInterruptCount)
        return backgroundJobInterruptCount
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        for event in promptEvents {
            await onEvent(event)
        }
        if let sendPromptError {
            throw sendPromptError
        }
        return DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func lastCreatedHistory() -> [AgentRuntimeMessage]? {
        createdHistories.last
    }

    func interruptedRootSessionIDs() -> [String] {
        interruptedRoots
    }
}
