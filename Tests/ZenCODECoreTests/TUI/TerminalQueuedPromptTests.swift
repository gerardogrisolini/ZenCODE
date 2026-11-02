//
//  TerminalQueuedPromptTests.swift
//  ZenCODECoreTests
//
//  Drives the production panel FIFO: a prompt the operator submits while a
//  turn is generating is queued and runs once that turn ends. Nothing here
//  touches a model or a terminal.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite
struct TerminalQueuedPromptTests {
    @ChatSessionActor
    private final class Harness {
        let terminal: TerminalChat
        let queue = TerminalChatEventQueue()
        let recorder = QueuedPromptRecorder()
        let firstGenerationGate = QueuedPromptFirstGenerationGate()

        init() throws {
            terminal = TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "remote-community/test",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    workingDirectory: URL(
                        fileURLWithPath: "/tmp/queued-prompt-\(UUID().uuidString)",
                        isDirectory: true
                    )
                ),
                stdinIsTerminal: false
            )
            terminal.interactiveRuntimeEventQueueForTesting = queue
            terminal.bypassInteractivePanelInputForTesting = true
            let recorder = recorder
            let gate = firstGenerationGate
            terminal.onGenerateResponseForTesting = { attempt in
                recorder.recordPrompt(attempt.prompt)
                // Only the first generation is held, so the queued prompt
                // arrives while a turn is in flight and then runs freely.
                await gate.holdIfFirst()
                return TerminalChatGenerationSuccess(
                    response: DirectAgentResponse(text: "Risposta.", stopReason: "stop", modelID: "test"),
                    origin: attempt.origin,
                    fileChangeSummary: nil,
                    automaticallyCompletedPlan: nil,
                    finalAssistantContent: "Risposta."
                )
            }
        }

        func submit(_ line: String) {
            queue.send(.input(.submitted(line)))
        }

        /// The queued-prompt count the loop last published to the panel.
        var panelQueuedPromptCount: Int {
            terminal.interactiveReader.withPanelLock { $0.panelQueuedPromptCount }
        }

        func panelQueuedPromptCountReached(_ expected: Int, timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while panelQueuedPromptCount != expected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return panelQueuedPromptCount == expected
        }

        func promptsReached(_ expected: [String], timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while recorder.prompts != expected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return recorder.prompts == expected
        }

        func run() async -> Task<Void, Error> {
            let terminal = terminal
            let loop = Task { try await terminal.runInteractivePanelLoop() }
            while terminal.voiceEventQueue !== queue {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return loop
        }

        func finish(_ loop: Task<Void, Error>) async throws {
            queue.send(.input(.endOfInput))
            try await loop.value
        }
    }

    @Test("A local prompt queued during a turn runs after it, and the queue empties")
    func aLocalPromptQueuedDuringATurnRunsAfterIt() async throws {
        let harness = try Harness()
        let loop = await harness.run()

        harness.submit("primo prompt")
        await harness.firstGenerationGate.waitUntilEntered()
        harness.submit("secondo prompt")
        let queued = await harness.panelQueuedPromptCountReached(1)
        #expect(queued)

        await harness.firstGenerationGate.release()
        let bothRan = await harness.promptsReached(["primo prompt", "secondo prompt"])
        #expect(bothRan)
        #expect(harness.recorder.prompts == ["primo prompt", "secondo prompt"])
        let drained = await harness.panelQueuedPromptCountReached(0)
        #expect(drained)

        try await harness.finish(loop)
    }
}

private final class QueuedPromptRecorder: Sendable {
    private let state = Mutex([String]())

    func recordPrompt(_ prompt: String) {
        state.withLock { $0.append(prompt) }
    }

    var prompts: [String] {
        state.withLock { $0 }
    }
}

/// Holds the first generation until released; every later one passes.
private actor QueuedPromptFirstGenerationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdIfFirst() async {
        guard !entered else { return }
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
