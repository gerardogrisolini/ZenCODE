//
//  TerminalTelegramOverviewMirroringTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

/// Thread-safe collector for the messages a test reporter delivers.
private final class TelegramMessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messagesStorage: [String] = []

    func append(_ message: String) {
        lock.lock()
        messagesStorage.append(message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messagesStorage
    }
}

/// Deterministic gate: lets a test hold one reporter delivery in flight
/// across a turn boundary, and exposes when a delivery has actually entered
/// the gate so the test can sequence turn boundaries deterministically.
private actor TelegramGate {
    private var isOpen = false
    private var enteredCount = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let toResume = waiters
        waiters.removeAll()
        for waiter in toResume {
            waiter.resume()
        }
    }

    /// Waits until one delivery has reached the gate. Entering the gate
    /// proves the mirror handler already captured the turn's reporter and is
    /// suspended inside its send.
    func waitUntilEntered() async {
        guard enteredCount < 1 else { return }
        await withCheckedContinuation { continuation in
            if enteredCount >= 1 {
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
            }
        }
    }

    func waitIfClosed() async {
        enteredCount += 1
        let toResume = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in toResume {
            waiter.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

@TerminalChatActor
@Suite
struct TerminalTelegramOverviewMirroringTests {
    private func makeTemp() throws -> (
        root: URL,
        support: URL,
        working: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TelegramOverviewMirroringTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let working = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: working,
            withIntermediateDirectories: true
        )
        return (root, support, working)
    }

    private func makeTerminal(
        working: URL,
        support: URL
    ) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: working
        )
        let runner = AgentCoreSessionRunner(
            taskGraphStore: SessionTaskGraphStore(
                supportDirectoryURL: support
            )
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: runner
        )
    }

    /// Deterministic replacement for fixed sleeps: first hand every mirror to
    /// the reporter, then wait for the reporter's own delivery queue. The two
    /// queues are intentionally independent in production.
    @discardableResult
    private func drainMirrors(
        _ terminal: TerminalChat
    ) async -> TerminalChat {
        await terminal.renderCoordinator.waitForOverviewMirrorsToDrain()
        await terminal.activeTelegramProgressReporter?.flush()
        return terminal
    }

    @Test
    func renderedTaskGraphOverviewIsMirroredWithoutANSI() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            recorder.append(message)
            return true
        }

        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v1",
            markdown: "## Task graph\n\n\u{1B}[32m▸ 1 running\u{1B}[0m",
            force: true
        )
        await drainMirrors(terminal)

        let message = try #require(recorder.messages.first)
        #expect(message.hasPrefix("📋 Task graph"))
        #expect(message.contains("## Task graph"))
        #expect(message.contains("▸ 1 running"))
        #expect(!message.contains("\u{1B}["))
    }

    @Test
    func identicalOverviewSignatureIsMirroredOnlyOncePerTurn() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            recorder.append(message)
            return true
        }

        let markdown = "## Task graph\n\nAll good."
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v1",
            markdown: markdown,
            force: true
        )
        await drainMirrors(terminal)
        #expect(recorder.messages.count == 1)

        // A forced re-render of an identical section must not re-mirror.
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v1",
            markdown: markdown,
            force: true
        )
        await drainMirrors(terminal)
        #expect(recorder.messages.count == 1)

        // A genuinely changed section mirrors again.
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v2",
            markdown: "## Task graph\n\nOne task failed.",
            force: true
        )
        await drainMirrors(terminal)
        #expect(recorder.messages.count == 2)
        #expect(recorder.messages.last?.contains("One task failed.") == true)
    }

    @Test
    func visibleSubAgentResponseBlocksAreMirroredOnceWithoutOverviewMetadata() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            recorder.append(message)
            return true
        }

        let first = TerminalChatRenderCoordinator.SubAgentPartialResponse(
            token: "worker\u{1F}partial\u{1F}1",
            heading: "💬 Response from worker:",
            markdown: "I found the **first** clue."
        )
        await terminal.renderCoordinator.renderSubAgentOverview(
            signature: "agents-v1",
            text: "Sub-agents\nagent metadata\n💬 I found the first clue.\n",
            partialResponses: [first],
            force: true,
            rememberSignature: true
        )
        // A forced redraw of the same live row must not duplicate the remote
        // response. A later tool boundary has a new revision and is delivered.
        await terminal.renderCoordinator.renderSubAgentOverview(
            signature: "agents-v1-redraw",
            text: "Sub-agents\nagent metadata\n💬 I found the first clue.\n",
            partialResponses: [first],
            force: true,
            rememberSignature: true
        )
        let second = TerminalChatRenderCoordinator.SubAgentPartialResponse(
            token: "worker\u{1F}partial\u{1F}2",
            heading: "💬 Response from worker:",
            markdown: "Now I have the complete intermediate result."
        )
        await terminal.renderCoordinator.renderSubAgentOverview(
            signature: "agents-v2",
            text: "Sub-agents\nagent metadata\n💬 complete intermediate result\n",
            partialResponses: [second],
            force: true,
            rememberSignature: true
        )
        await drainMirrors(terminal)

        #expect(recorder.messages == [
            "💬 Response from worker:\n\nI found the **first** clue.",
            "💬 Response from worker:\n\nNow I have the complete intermediate result."
        ])
        #expect(recorder.messages.allSatisfy { !$0.contains("agent metadata") })
        #expect(terminal.mirroredTaskGraphOverviewSignature == nil)
    }

    @Test
    func completedSubAgentResponsesAreSeparateMarkdownOnlyMessages() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            recorder.append(message)
            return true
        }
        let first = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "worker\u{1F}1",
            heading: "\u{1B}[36m   ✅ Response from worker:\u{1B}[0m\n",
            markdown: "**First** answer"
        )
        let second = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "reviewer\u{1F}1",
            heading: "   ✅ Response from reviewer:\n",
            markdown: "Second answer"
        )

        await terminal.renderCoordinator.renderSubAgentOverview(
            signature: "agents:completed",
            text: "thinking marker\ntool marker\nagent metadata\n",
            responses: [first, second],
            force: false,
            rememberSignature: true
        )
        await drainMirrors(terminal)

        let messages = recorder.messages
        #expect(messages.count == 2)
        #expect(messages[0] == "✅ Response from worker:\n\n**First** answer")
        #expect(messages[1] == "✅ Response from reviewer:\n\nSecond answer")
        #expect(messages.allSatisfy { !$0.contains("\u{1B}[") })
        #expect(messages.allSatisfy { !$0.contains("thinking marker") })
        #expect(messages.allSatisfy { !$0.contains("tool marker") })
        #expect(messages.allSatisfy { !$0.contains("agent metadata") })
    }

    @Test
    func overviewWithoutActiveReporterStaysTerminalOnly() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        // No reporter: mirroring must be a silent no-op.
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v1",
            markdown: "## Task graph\n\nQuiet.",
            force: true
        )
        await drainMirrors(terminal)
        #expect(terminal.activeTelegramProgressReporter == nil)
        #expect(terminal.mirroredTaskGraphOverviewSignature == nil)
    }

    @Test
    func newTurnResetsTheMirroringDedup() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        func makeRecorderReporter() -> TerminalTelegramTurnProgressReporter {
            TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
                recorder.append(message)
                return true
            }
        }
        terminal.activeTelegramProgressReporter = makeRecorderReporter()

        let markdown = "## Task graph\n\nSame content across turns."
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v1",
            markdown: markdown,
            force: true
        )
        await drainMirrors(terminal)
        #expect(recorder.messages.count == 1)

        // A new turn resets the per-turn dedup; activating Telegram state
        // makes beginTelegramTurnProgressReporting rebuild its own reporter,
        // which the test then replaces with the recording one.
        terminal.telegramControlState.isActive = true
        terminal.telegramLinkedChatID = 42
        await terminal.beginTelegramTurnProgressReporting(for: .telegram(chatID: 42))
        terminal.activeTelegramProgressReporter = makeRecorderReporter()

        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v1",
            markdown: markdown,
            force: true
        )
        await drainMirrors(terminal)
        #expect(recorder.messages.count == 2)
    }

    @Test
    func mirrorDeliveryPreservesRenderOrderAcrossSectionsAndRevisions()
        async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            recorder.append(message)
            return true
        }

        // A metadata-only sub-agent section has no remote payload; task-graph
        // revisions still reach Telegram in their exact local render order.
        await terminal.renderCoordinator.renderSubAgentOverview(
            signature: "agents-v1",
            text: "Sub-agents\nfirst wave",
            force: true,
            rememberSignature: true
        )
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v1",
            markdown: "## Task graph\n\nfirst revision",
            force: true
        )
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-v2",
            markdown: "## Task graph\n\nsecond revision",
            force: true
        )
        await drainMirrors(terminal)

        let messages = recorder.messages
        #expect(messages.count == 2)
        #expect(messages[0].hasPrefix("📋 Task graph"))
        #expect(messages[0].contains("first revision"))
        #expect(messages[1].hasPrefix("📋 Task graph"))
        #expect(messages[1].contains("second revision"))
    }

    @Test
    func finalizingTheTurnDeliversMirrorsThenRetiresTheReporter() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            recorder.append(message)
            return true
        }

        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-final",
            markdown: "## Task graph\n\nTurn is ending.",
            force: true
        )
        await terminal.finalizeTelegramTurnProgressReporting()

        // The queued section was delivered before the reporter retired.
        let message = try #require(recorder.messages.first)
        #expect(message.contains("Turn is ending."))
        #expect(terminal.activeTelegramProgressReporter == nil)
        #expect(terminal.activeTelegramTurnOrigin == nil)

        // Post-turn publications — even brand-new signatures — are
        // terminal-only by contract and must not reach the remote chat.
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-after-turn",
            markdown: "## Task graph\n\nAfter the turn.",
            force: true
        )
        await drainMirrors(terminal)
        #expect(recorder.messages.count == 1)
    }

    @Test
    func deferredOverviewMirrorsWhenPublicationResumes() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        let recorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            recorder.append(message)
            return true
        }

        // While publication is suspended (as during streaming) the section is
        // deferred and must not mirror yet.
        await terminal.renderCoordinator.setOverviewPublishingSuspended(true)
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-deferred",
            markdown: "## Task graph\n\nDeferred section.",
            force: true
        )
        await drainMirrors(terminal)
        #expect(recorder.messages.isEmpty)

        // Resuming publication renders the deferred section locally and its
        // mirror follows, in order, through the same FIFO drain.
        await terminal.renderCoordinator.setOverviewPublishingSuspended(false)
        await drainMirrors(terminal)

        let message = try #require(recorder.messages.first)
        #expect(message.hasPrefix("📋 Task graph"))
        #expect(message.contains("Deferred section."))
    }

    @Test
    func staleMirrorNotificationIsNotAdoptedByTheNextTurn() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeTerminal(working: working, support: support)
        await terminal.installOverviewMirroringHandler()

        // Turn 1: a reporter whose delivery blocks on a closed gate.
        terminal.telegramControlState.isActive = true
        terminal.telegramLinkedChatID = 42
        await terminal.beginTelegramTurnProgressReporting(for: .telegram(chatID: 42))
        let firstTurnRecorder = TelegramMessageRecorder()
        let gate = TelegramGate()
        let firstTurnReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            await gate.waitIfClosed()
            firstTurnRecorder.append(message)
            return true
        }
        terminal.activeTelegramProgressReporter = firstTurnReporter

        // Section A enters delivery (blocked on the gate); section B queues
        // behind it and is not delivered yet.
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-turn1-a",
            markdown: "## Task graph\n\nTurn 1 section A.",
            force: true
        )
        await terminal.renderCoordinator.renderTaskGraphOverview(
            signature: "graph-turn1-b",
            markdown: "## Task graph\n\nTurn 1 section B.",
            force: true
        )
        // Prove A's delivery already captured turn 1's reporter and is
        // suspended inside its send before the next turn begins.
        await gate.waitUntilEntered()

        // Turn 2 begins (epoch advanced) with its own reporter before the
        // blocked delivery resumes.
        await terminal.beginTelegramTurnProgressReporting(for: .telegram(chatID: 42))
        let secondTurnRecorder = TelegramMessageRecorder()
        terminal.activeTelegramProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            secondTurnRecorder.append(message)
            return true
        }

        await gate.open()
        await drainMirrors(terminal)
        // `drainMirrors` flushes the currently active turn-2 reporter. The
        // delivery already captured by turn 1 has its own queue, so wait for
        // that reporter explicitly before observing its recorder.
        await firstTurnReporter.flush()

        // A was already in delivery for turn 1's reporter: it stays there.
        #expect(firstTurnRecorder.messages.count == 1)
        #expect(firstTurnRecorder.messages.first?.contains("Turn 1 section A.") == true)
        // B carries turn 1's epoch and must be discarded, not adopted by
        // turn 2's reporter.
        #expect(secondTurnRecorder.messages.isEmpty)
    }
}
