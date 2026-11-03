//
//  ZenScriptedBackend.swift
//  ZenAppSessionTests
//
//  The test doubles of the window tests: a scripted model backend, a gate a
//  step waits at, and bounded waits.
//

import Foundation
import Observation
import Synchronization
import Testing
import ToolCore
import ZenCODECore

/// Counts the changes Observation reports for what `read` reads, for as long
/// as the counter lives.
@MainActor
final class ZenObservationCounter {
    private(set) var count = 0
    private let read: @MainActor () -> Void

    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        track()
    }

    private func track() {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.count += 1
                self.track()
            }
        }
    }
}

/// The longest any wait of the tests lasts before it records an issue.
let zenTestDeadline: Duration = .seconds(10)

/// Polls `condition` until it holds or `timeout` passes; records an issue
/// naming `what` on timeout.
@discardableResult
func waitUntil(
    _ what: String,
    timeout: Duration = zenTestDeadline,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if await condition() { return true }
    Issue.record("Timed out waiting until \(what)", sourceLocation: sourceLocation)
    return false
}

/// A gate a step passes only once the test opens it; the test can tell when
/// the step reached it. Every wait is bounded.
actor ZenGate {
    private var isOpen = false
    private(set) var reached = false

    func pass() async {
        reached = true
        let deadline = ContinuousClock.now + zenTestDeadline
        while !isOpen {
            guard ContinuousClock.now < deadline else {
                Issue.record("The gate was never opened")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        isOpen = true
    }
}

/// What happened to a scripted backend and its held turn, in order. The
/// cancellation of a held turn is recorded synchronously, by the task that
/// cancels it.
final class ZenBackendLifecycle: Sendable {
    enum Event: Equatable, Sendable {
        /// The runner shut the backend down.
        case backendShutDown
        /// The task of a held turn was cancelled.
        case heldTurnCancelled
    }

    private let storage = Mutex<[Event]>([])

    var events: [Event] {
        storage.withLock { $0 }
    }

    func append(_ event: Event) {
        storage.withLock { $0.append(event) }
    }
}

/// A model backend that answers every prompt with one scripted block, can
/// hold a turn until the test releases it, and reports scripted sub-agents.
/// Every wait is bounded.
actor ZenScriptedBackend: AgentRuntimeBackend {
    struct HoldTimedOut: Error {}

    /// The shutdown of the backend and the cancellations of its held turns.
    nonisolated let lifecycle = ZenBackendLifecycle()

    private(set) var prompts: [String] = []
    /// The attachments of each prompt, in the order of ``prompts``.
    private(set) var attachments: [[AgentRuntimeAttachment]] = []
    /// The system prompts the sessions were created or updated with.
    private(set) var systemPrompts: [String] = []
    private var scripts: [String: [DirectAgentEvent]] = [:]
    private var subAgents: [DirectSubAgentRuntime.AgentSnapshot] = []
    private var holdsNextTurn = false
    private(set) var isHolding = false
    private var released = false

    func hold() {
        holdsNextTurn = true
        released = false
    }

    func release() {
        released = true
    }

    /// Waits until a turn is held; `false`, with an issue, on timeout.
    @discardableResult
    func waitUntilHeld(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let deadline = ContinuousClock.now + zenTestDeadline
        while !isHolding {
            guard ContinuousClock.now < deadline else {
                Issue.record("No turn was held", sourceLocation: sourceLocation)
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func script(prompt: String, events: [DirectAgentEvent]) {
        scripts[prompt] = events
    }

    func setSubAgents(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        subAgents = snapshots
    }

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        systemPrompts.append(systemPrompt ?? "")
    }

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        systemPrompts.append(systemPrompt ?? "")
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        systemPrompts.append(systemPrompt ?? "")
    }

    func closeSession(id _: String) {}

    func shutdown() async {
        lifecycle.append(.backendShutDown)
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "zen-app-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        subAgents
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments promptAttachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        attachments.append(promptAttachments)
        let key = scripts.keys.first { prompt.contains($0) }
        if holdsNextTurn {
            holdsNextTurn = false
            isHolding = true
            defer { isHolding = false }
            let deadline = ContinuousClock.now + zenTestDeadline
            let lifecycle = lifecycle
            try await withTaskCancellationHandler {
                while !released {
                    guard ContinuousClock.now < deadline else {
                        Issue.record("A held turn was never released")
                        throw HoldTimedOut()
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            } onCancel: {
                lifecycle.append(.heldTurnCancelled)
            }
        }
        if let key, let events = scripts[key] {
            for event in events {
                await onEvent(event)
            }
        }
        let name = key ?? prompt.components(separatedBy: .newlines).last ?? prompt
        let text = "Scripted answer to \(name)"
        await onEvent(.content(text))
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "zen-app-model")
    }
}
