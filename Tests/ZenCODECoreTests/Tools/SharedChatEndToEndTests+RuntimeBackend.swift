//
//  SharedChatEndToEndTests+RuntimeBackend.swift
//  ZenCODE
//
//  Minimal mock runtime backend of the shared chat end-to-end tests: it
//  records every prompt and can block a turn on demand.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Minimal mock backend

/// Minimal backend that records every prompt and can block `sendPrompt` on
/// demand, so tests can hold an agent in `.running` or park it in standby
/// without a model provider. Mirrors the patterns used by
/// ``SharedChatInlineDeliveryTests`` and ``DirectSubAgentRuntimeTests``.
actor EndToEndRuntimeBackend: AgentRuntimeBackend {
    private var prompts: [String] = []
    private var shouldBlock = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var promptCountWaiters: [PromptCountWaiter] = []
    private var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?

    private struct PromptCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    func setBlocking(_ value: Bool) {
        shouldBlock = value
    }

    func promptCount() -> Int { prompts.count }

    func prompt(at index: Int) -> String? {
        guard index >= 0, index < prompts.count else { return nil }
        return prompts[index]
    }

    /// A prompt is the delivery boundary this suite observes. Registering the
    /// waiter in the producer actor makes the edge race-free without polling.
    func waitUntilPromptCount(_ count: Int) async {
        guard prompts.count < count else { return }
        await withCheckedContinuation { continuation in
            promptCountWaiters.append(
                PromptCountWaiter(count: count, continuation: continuation)
            )
        }
    }

    func releasePrompt() {
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }

    func executeBorrowedSubAgentTool(_ toolCall: AgentBorrowedToolCall) async throws -> String {
        guard let borrowedSubAgentToolExecutor else {
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        return try await borrowedSubAgentToolExecutor(toolCall)
    }

    private func waitForRelease() async {
        guard shouldBlock else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    // MARK: AgentRuntimeBackend

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

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

    func updateBorrowedSubAgentToolExecutor(_ executor: AgentBorrowedToolExecutor?) async {
        borrowedSubAgentToolExecutor = executor
    }

    func closeSession(id _: String) async {}

    func shutdown() async {
        releasePrompt()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        resumePromptCountWaiters()
        await waitForRelease()
        return DirectAgentResponse(
            text: "done",
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    private func resumePromptCountWaiters() {
        let ready = promptCountWaiters.filter { prompts.count >= $0.count }
        promptCountWaiters.removeAll { prompts.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
