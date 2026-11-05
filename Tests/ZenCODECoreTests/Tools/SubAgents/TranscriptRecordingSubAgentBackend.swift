import Foundation
import ToolCore
@testable import ZenCODECore

/// A sub-agent backend that keeps a real per-session history, as
/// `AgentCoreBackend` does: every prompt appends the user message, one
/// assistant message with reasoning and a tool call, the tool result, and
/// (unless the turn blocks) the final assistant text. `shutdown()` drops
/// every session, so a history read after it finds nothing, as a real
/// backend that was shut down.
actor TranscriptRecordingSubAgentBackend: AgentRuntimeBackend {
    enum PromptOutcome: Sendable {
        /// The turn completes with the final assistant text.
        case respond
        /// The turn records its tool round, then suspends until it is
        /// cancelled, and throws `CancellationError`.
        case blockUntilCancelled
    }

    private let outcome: PromptOutcome
    private var histories: [String: [AgentRuntimeMessage]] = [:]
    private var workingDirectories: [String: String] = [:]
    private var shutdownCalls = 0
    private var shutdownWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    init(outcome: PromptOutcome = .respond) {
        self.outcome = outcome
    }

    // MARK: Test probes

    func shutdownCount() -> Int {
        shutdownCalls
    }

    func waitUntilShutdownCount(_ count: Int) async {
        guard shutdownCalls < count else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append((count, continuation))
        }
    }

    /// Returns once a `.blockUntilCancelled` turn recorded its tool round and
    /// suspended.
    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    // MARK: AgentRuntimeBackend

    func createSession(
        id: String,
        cwd: String,
        systemPrompt _: String?,
        history: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        histories[id] = history
        workingDirectories[id] = cwd
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
        guard histories[id] == nil else { return }
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

    func closeSession(id: String) {
        histories.removeValue(forKey: id)
        workingDirectories.removeValue(forKey: id)
    }

    func shutdown() {
        histories.removeAll()
        workingDirectories.removeAll()
        shutdownCalls += 1
        let ready = shutdownWaiters.filter { shutdownCalls >= $0.count }
        shutdownWaiters.removeAll { shutdownCalls >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
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
        append(AgentRuntimeMessage(role: .user, content: prompt), to: sessionID)
        let callID = "call-\(histories[sessionID]?.count ?? 0)-0"
        append(
            AgentRuntimeMessage(
                role: .assistant,
                content: "Reading round 0.",
                reasoningContent: "Round 0 needs the file.",
                toolCalls: [
                    AgentRuntimeToolCall(
                        id: callID,
                        name: "local.readFile",
                        argumentsJSON: #"{"path":"round-0.txt"}"#
                    ),
                ]
            ),
            to: sessionID
        )
        append(
            AgentRuntimeMessage(
                role: .tool,
                content: "contents of round 0",
                toolCallID: callID,
                toolName: "local.readFile"
            ),
            to: sessionID
        )
        switch outcome {
        case .respond:
            append(AgentRuntimeMessage(role: .assistant, content: "Finished: \(prompt)"), to: sessionID)
            return DirectAgentResponse(
                text: "Finished: \(prompt)",
                stopReason: "stop",
                modelID: "test-model"
            )
        case .blockUntilCancelled:
            await waitForCancellation()
            throw CancellationError()
        }
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        guard let history = histories[id] else { return nil }
        return AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: workingDirectories[id] ?? "/tmp",
            systemPrompt: nil,
            cacheKey: nil,
            history: history,
            allowedToolNames: nil,
            thinkingSelection: nil,
            preserveThinking: false
        )
    }

    // MARK: Private

    private func append(_ message: AgentRuntimeMessage, to sessionID: String) {
        histories[sessionID, default: []].append(message)
    }

    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var cancellationRequested = false

    private func waitForCancellation() async {
        await withTaskCancellationHandler {
            await suspendUntilCancelled()
        } onCancel: {
            Task { await self.resumeCancelledTurn() }
        }
    }

    private func suspendUntilCancelled() async {
        guard !cancellationRequested, !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            cancellationContinuation = continuation
            isBlocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func resumeCancelledTurn() {
        cancellationRequested = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
}
