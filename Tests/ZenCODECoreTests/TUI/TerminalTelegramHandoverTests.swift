//
//  TerminalTelegramHandoverTests.swift
//  ZenCODECoreTests
//
//  The terminal's real input loop while its slot goes to Telegram and back:
//  the queue that waits, whole, while Telegram drives and runs after
//  `/telegram off` (a `/telegram off` typed meanwhile included); a turn of
//  the terminal that moves to Telegram and back with its final answer; a
//  turn of the terminal whose ending went to Telegram, never read aloud; a
//  turn adopted from Telegram (generating state, status bar, final content
//  without the text the catch-up showed, Esc that stops it); the catch-up
//  rendered before anything more of the adopted turn, with what the turn
//  presented meanwhile shown after it; the dormant terminal that refuses
//  dictation, mentions by voice, and the access-mode shortcut; and, without
//  the loop, `/telegram on` refused, `/telegram off` that tells the link
//  stopped, and the catch-up title above a response in progress. The model
//  is a scripted backend, Telegram a scripted Bot API, and every test runs
//  in a UUID-named support directory.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Terminal Telegram handover", .serialized, .timeLimit(.minutes(2)))
struct TerminalTelegramHandoverTests {
    /// The terminal of a test with its real input loop, fed through its
    /// event queue: a scripted model, a scripted Bot API, captured writes.
    @ChatSessionActor
    private final class Harness {
        let terminal: TerminalChat
        let queue = TerminalChatEventQueue()
        let backend: TerminalHandoverBackend
        let transport: ACPTelegramScriptedTransport
        let voice = TerminalHandoverVoiceController()
        let generationStates = TelegramTestRecorder<Bool>()
        let publications = TelegramTestRecorder<Int>()

        init(root: URL, voiceMode: Bool = false) throws {
            let workspace = root.appendingPathComponent("workspace-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let backend = TerminalHandoverBackend()
            let transport = ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            self.backend = backend
            self.transport = transport
            terminal = TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "test-model",
                    explicitModelID: "test-model",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    availableModels: [
                        AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                    ],
                    workingDirectory: workspace
                ),
                stdinIsTerminal: false,
                sessionRunner: AgentCoreSessionRunner(backendFactory: backend.factory, taskGraphStore: nil),
                telegramTransportFactory: { transport },
                renderCoordinator: TerminalChatRenderCoordinator(
                    stdinIsTerminal: false,
                    standardOutput: nil,
                    standardError: nil,
                    standardOutputIsTerminal: false,
                    standardErrorIsTerminal: false,
                    cursorTopology: .separate,
                    capturesWrites: true,
                    streamingFlushDelay: nil,
                    columnWidthProvider: { 100 }
                )
            )
            terminal.interactiveRuntimeEventQueueForTesting = queue
            terminal.bypassInteractivePanelInputForTesting = true
            let generationStates = generationStates
            terminal.onInteractiveGenerationStateForTesting = { generationStates.append($0) }
            let publications = publications
            terminal.onSharedChatPublicationForTesting = {
                publications.append(1)
                return true
            }
            if voiceMode {
                terminal.voiceController = voice
            }
        }

        var slot: ChatSlotID {
            terminal.terminalSlotID
        }

        var activeChannel: ChatSlotChannel {
            terminal.sessionHost.activeChannel(in: slot)
        }

        /// Creates the session and starts the loop, once it reads its queue.
        func run() async throws -> Task<Void, Error> {
            try await terminal.createCurrentSession(discoverExternalTools: false)
            let terminal = terminal
            let loop = Task { @ChatSessionActor in try await terminal.runInteractivePanelLoop() }
            _ = await waitUntil { terminal.loopEventQueue === self.queue }
            return loop
        }

        func submit(_ line: String) {
            queue.send(.input(.submitted(line)))
        }

        func dictate(_ prompt: String) {
            queue.send(.voicePromptCompleted(TerminalVoicePromptResult(origin: .local, outcome: .success(prompt))))
        }

        /// Ends the loop and shuts the host down.
        func finish(_ loop: Task<Void, Error>) async throws {
            queue.send(.input(.endOfInput))
            try await loop.value
            await terminal.sessionHost.shutdown()
        }

        /// What the terminal wrote so far.
        func output() async -> String {
            await terminal.renderCoordinator.capturedWriteEvents().map(\.text).joined()
        }

        var panelQueuedPromptCount: Int {
            terminal.interactiveReader.withPanelLock { $0.panelQueuedPromptCount }
        }

        var panelIsProcessing: Bool {
            terminal.interactiveReader.withPanelLock { $0.panelIsProcessing }
        }

        /// `/telegram on`, typed, until Telegram drives the slot.
        func turnTelegramOn() async -> Bool {
            submit("/telegram on")
            return await waitUntil { self.activeChannel == .telegram }
        }

        /// `/telegram off`, typed, until the terminal drives the slot.
        func turnTelegramOff() async -> Bool {
            submit("/telegram off")
            return await waitUntil { self.activeChannel == .primary }
        }

        /// A prompt from the linked chat, until the model pauses in it.
        func startTelegramTurn(_ prompt: String) async throws -> Bool {
            try await transport.deliver(prompt)
            return await waitUntil { await self.backend.isPaused }
        }

        /// Until the loop reported `count` changes of its generating state,
        /// the last one `false`.
        func generationEnded(after count: Int) async -> Bool {
            await waitUntil {
                self.generationStates.values.count >= count && self.generationStates.values.last == false
            }
        }

        /// Until the loop ended its generation (``generationEnded(after:)``)
        /// and wrote `finalText`, which only the presentation of the turn's
        /// ending writes: the loop reports that it no longer generates before
        /// it presents the ending (`finishPromptResult`), so the generating
        /// state alone does not tell that what the terminal wrote is final.
        func turnEnded(after count: Int, writing finalText: String) async -> Bool {
            guard await generationEnded(after: count) else { return false }
            return await waitUntil { await self.output().contains(finalText) }
        }

        /// Lets the loop settle, then sends `/telegram`, which a dormant
        /// terminal still runs, and waits for the status it writes: every
        /// event sent before it was handled.
        func settle() async -> Bool {
            try? await Task.sleep(for: .milliseconds(150))
            if terminal.capturedCommandOutputForTesting == nil {
                terminal.capturedCommandOutputForTesting = []
            }
            let before = terminal.capturedCommandOutputForTesting?.count ?? 0
            submit("/telegram")
            return await waitUntil {
                (self.terminal.capturedCommandOutputForTesting ?? [])
                    .dropFirst(before)
                    .contains { $0.hasPrefix("Telegram: ") }
            }
        }

        func waitUntil(
            timeout: Duration = .seconds(10),
            _ condition: @ChatSessionActor () async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await condition()
        }
    }

    /// Runs `body` on the chat actor in a UUID support directory holding the
    /// paired Telegram settings.
    private nonisolated func withEnvironment(
        _ body: @escaping @Sendable @ChatSessionActor (URL) async throws -> Void
    ) async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            try await Task(name: "ZenCODE.Tests.terminal-telegram-handover") { @ChatSessionActor in
                try await body(root)
            }.value
        }
    }

    private static func occurrences(of text: String, in output: String) -> Int {
        output.components(separatedBy: text).count - 1
    }

    // MARK: - Queue

    /// A typed prompt and a dictated one queued during a turn of the
    /// terminal, before `/telegram on`, neither start nor get lost while
    /// Telegram drives the slot, not even once that turn ended in the chat;
    /// the `/telegram off` typed then runs at once instead of queuing behind
    /// them, and both run after it, in order.
    @Test
    nonisolated func promptsQueuedBeforeTelegramOnWaitWholeAndRunAfterTelegramOff() async throws {
        try await withEnvironment { root in
            let harness = try Harness(root: root)
            await harness.backend.enqueue([.reply("first answer"), .pause])
            let loop = try await harness.run()

            harness.submit("primo")
            #expect(await harness.waitUntil { await harness.backend.isPaused })
            harness.submit("scritto")
            harness.dictate("vocale")
            #expect(await harness.waitUntil { harness.panelQueuedPromptCount == 2 })

            #expect(await harness.turnTelegramOn())
            // The turn of the terminal ends in the chat; the queue waits.
            await harness.backend.release()
            #expect(await harness.generationEnded(after: 2))
            #expect(await harness.waitUntil {
                await harness.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(await harness.settle())
            #expect(await harness.backend.prompts == ["primo"])
            #expect(harness.panelQueuedPromptCount == 2)
            #expect(harness.activeChannel == .telegram)

            // `/telegram off` runs at once, then the queue does.
            #expect(await harness.turnTelegramOff())
            #expect(await harness.waitUntil { await harness.backend.prompts == ["primo", "scritto", "vocale"] })
            #expect(await harness.waitUntil { harness.panelQueuedPromptCount == 0 })
            #expect(await harness.turnEnded(after: 6, writing: "Answer to: vocale"))
            let output = await harness.output()
            #expect(output.contains("Answer to: scritto"))
            #expect(output.contains("Answer to: vocale"))
            try await harness.finish(loop)
        }
    }

    // MARK: - A turn of the terminal

    /// `/telegram on` in the middle of a turn of the terminal hands it to
    /// the chat, and `/telegram off` takes it back: the text goes on each
    /// time, and the terminal ends with the tail of the final block, after
    /// the catch-up that showed the rest, neither `Done.` nor the fragment
    /// it held before `/telegram on`.
    @Test
    nonisolated func aTurnOfTheTerminalThatGoesToTelegramAndBackEndsWithTheTailOfItsAnswer() async throws {
        try await withEnvironment { root in
            let harness = try Harness(root: root)
            await harness.backend.enqueue([.reply("ALPHA "), .pause, .reply("BETA "), .pause, .reply("GAMMA")])
            let loop = try await harness.run()

            harness.submit("domanda")
            #expect(await harness.waitUntil { await harness.backend.isPaused })
            #expect(await harness.turnTelegramOn())
            await harness.backend.release()
            #expect(await harness.waitUntil { await harness.backend.isPaused })

            #expect(await harness.turnTelegramOff())
            await harness.backend.release()
            #expect(await harness.turnEnded(after: 2, writing: "GAMMA"))

            let output = await harness.output()
            let catchUp = try #require(output.range(of: "Catch-up from Telegram:"))
            let inProgress = try #require(output.range(of: "Response in progress so far:"))
            let tail = try #require(output.range(of: "GAMMA"))
            #expect(catchUp.upperBound <= inProgress.lowerBound)
            #expect(inProgress.upperBound <= tail.lowerBound)
            #expect(output.contains("ALPHA BETA"))
            #expect(Self.occurrences(of: "ALPHA", in: output) == 1)
            #expect(Self.occurrences(of: "GAMMA", in: output) == 1)
            #expect(!output.contains("Done."))
            try await harness.finish(loop)
        }
    }

    /// A turn of the terminal that ends while Telegram drives the slot is
    /// presented in the chat: the dormant terminal neither writes its
    /// answer nor reads anything of it aloud.
    @Test
    nonisolated func aTurnOfTheTerminalThatEndsInTheChatIsNeitherWrittenNorReadAloud() async throws {
        try await withEnvironment { root in
            let harness = try Harness(root: root, voiceMode: true)
            await harness.backend.enqueue([.reply("held answer"), .pause, .reply(" ended remotely")])
            let loop = try await harness.run()

            harness.submit("domanda")
            #expect(await harness.waitUntil { await harness.backend.isPaused })
            #expect(await harness.turnTelegramOn())
            // The status line follows the switch of the slot, which the turn
            // in progress moves to the chat first.
            #expect(await harness.waitUntil {
                await harness.output().contains("Session driven from Telegram.")
            })
            await harness.backend.release()
            #expect(await harness.generationEnded(after: 2))
            #expect(await harness.waitUntil {
                await harness.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(await harness.settle())

            #expect(await harness.voice.spoken.isEmpty)
            let output = await harness.output()
            #expect(!output.contains("held answer"))
            #expect(!output.contains("ended remotely"))
            #expect(harness.activeChannel == .telegram)
            try await harness.finish(loop)
        }
    }

    // MARK: - A turn adopted from Telegram

    /// `/telegram off` while a turn from Telegram runs: the terminal adopts
    /// it (generating, status bar and panel processing), the catch-up shows
    /// the prompt and the text so far, and the turn, which says nothing
    /// more, ends with `Done.` instead of the whole response again.
    @Test
    nonisolated func anAdoptedTurnWithoutTextAfterTheSwitchEndsWithoutRepeatingTheResponse() async throws {
        try await withEnvironment { root in
            let harness = try Harness(root: root)
            let loop = try await harness.run()
            #expect(await harness.turnTelegramOn())
            await harness.backend.enqueue([.reply("remote answer"), .pause])
            #expect(try await harness.startTelegramTurn("remote question"))

            #expect(await harness.turnTelegramOff())
            #expect(await harness.waitUntil { harness.generationStates.values == [true] })
            // The loop marks itself generating, then the status bar and the
            // panel processing, in this order.
            #expect(await harness.waitUntil { harness.panelIsProcessing })
            #expect(await harness.terminal.statusBar.state.isProcessing)

            await harness.backend.release()
            #expect(await harness.turnEnded(after: 2, writing: "Done."))
            #expect(await harness.terminal.statusBar.state.isProcessing == false)
            #expect(!harness.panelIsProcessing)
            let output = await harness.output()
            let catchUp = try #require(output.range(of: "Catch-up from Telegram:"))
            let question = try #require(output.range(of: "remote question"))
            let answer = try #require(output.range(of: "remote answer"))
            let done = try #require(output.range(of: "Done."))
            #expect(catchUp.upperBound <= question.lowerBound)
            #expect(question.upperBound <= answer.lowerBound)
            #expect(answer.upperBound <= done.lowerBound)
            #expect(Self.occurrences(of: "remote answer", in: output) == 1)
            try await harness.finish(loop)
        }
    }

    /// Esc stops a turn the terminal adopted from Telegram, which runs
    /// without a task of the loop: its reservation drops at once and the
    /// turn ends as a stopped one.
    @Test
    nonisolated func escStopsATurnAdoptedFromTelegram() async throws {
        try await withEnvironment { root in
            let harness = try Harness(root: root)
            let loop = try await harness.run()
            #expect(await harness.turnTelegramOn())
            await harness.backend.enqueue([.reply("partial"), .pause, .reply(" never shown")])
            #expect(try await harness.startTelegramTurn("long task"))
            #expect(await harness.turnTelegramOff())
            #expect(await harness.waitUntil { harness.generationStates.values == [true] })
            #expect(harness.terminal.sessionHost.activePromptID(in: harness.slot) != nil)

            harness.queue.send(.input(.cancelRequested))
            #expect(await harness.waitUntil { harness.terminal.sessionHost.activePromptID(in: harness.slot) == nil })
            await harness.backend.release()
            #expect(await harness.turnEnded(after: 2, writing: "Stopped."))
            let output = await harness.output()
            #expect(output.contains("Stopped."))
            #expect(!output.contains("never shown"))
            try await harness.finish(loop)
        }
    }

    /// The catch-up comes before anything more of the adopted turn: a tool
    /// call the turn starts while the terminal renders the catch-up is
    /// shown after it, not lost and not in the middle of it.
    @Test
    nonisolated func whatTheAdoptedTurnPresentsDuringTheCatchUpFollowsIt() async throws {
        try await withEnvironment { root in
            let harness = try Harness(root: root)
            let loop = try await harness.run()
            #expect(await harness.turnTelegramOn())
            await harness.backend.enqueue([
                .reply("PRIMA-MARKER"), .pause, .readFile(path: "handover-marker.txt"), .reply("DOPO-MARKER"),
            ])
            #expect(try await harness.startTelegramTurn("remote question"))

            // The terminal reads the active tools while it renders the
            // catch-up: the turn goes on right then.
            await harness.backend.releaseAtNextToolDescriptorsRead()
            #expect(await harness.turnTelegramOff())
            #expect(await harness.turnEnded(after: 2, writing: "DOPO-MARKER"))
            #expect(await harness.backend.startedToolCallCount == 1)

            let output = await harness.output()
            let question = try #require(output.range(of: "remote question"))
            let inProgress = try #require(output.range(of: "Response in progress so far:"))
            let before = try #require(output.range(of: "PRIMA-MARKER"))
            let marker = try #require(output.range(of: "local.readFile"))
            let after = try #require(output.range(of: "DOPO-MARKER"))
            #expect(question.upperBound <= inProgress.lowerBound)
            #expect(inProgress.upperBound <= before.lowerBound)
            #expect(before.upperBound <= marker.lowerBound)
            #expect(marker.upperBound <= after.lowerBound)
            #expect(Self.occurrences(of: "PRIMA-MARKER", in: output) == 1)
            try await harness.finish(loop)
        }
    }

    // MARK: - Dormant

    /// While Telegram drives the slot a dictation is refused whatever it
    /// reads (a dictated `/telegram off` or `/exit` is not a command), and
    /// so are a mention by voice and the access-mode shortcut: each answers
    /// the dormant text and changes nothing.
    @Test
    nonisolated func theDormantTerminalRefusesDictationMentionsByVoiceAndTheAccessShortcut() async throws {
        try await withEnvironment { root in
            let harness = try Harness(root: root, voiceMode: true)
            let loop = try await harness.run()
            #expect(await harness.turnTelegramOn())
            let accessMode = await harness.terminal.sessionRunner.localExecAccessMode()
            harness.terminal.capturedCommandOutputForTesting = []

            harness.dictate("/telegram off")
            harness.dictate("/exit")
            harness.dictate("scrivi i test")
            harness.queue.send(.voiceUtterance("messaggio al coordinatore: fermati"))
            harness.queue.send(.input(.toggleAccessModeRequested))
            #expect(await harness.settle())

            let refusals = (harness.terminal.capturedCommandOutputForTesting ?? [])
                .filter { $0 == ChatSlotAdmission.dormantRefusalText }
            #expect(refusals.count == 5)
            #expect(harness.activeChannel == .telegram)
            #expect(await harness.backend.prompts.isEmpty)
            #expect(harness.publications.values.isEmpty)
            #expect(await harness.voice.spoken.isEmpty)
            #expect(await harness.terminal.sessionRunner.localExecAccessMode() == accessMode)
            try await harness.finish(loop)
        }
    }

    // MARK: - Without the loop

    /// The line-by-line fallback (a terminal without the status bar, as with
    /// standard error redirected) neither reserves its prompts nor adopts a
    /// turn: `/telegram on` is refused there, and the slot stays the
    /// terminal's, without a Telegram channel.
    @Test
    func telegramOnIsRefusedOutsideTheInteractiveLoop() async throws {
        try await TelegramChannelTestSupport.withSupport {
            let transport = TelegramChannelTestTransport(botID: TelegramChannelTestSupport.uniqueBotID())
            let terminal = try TelegramChannelTestSupport.makeTerminal(transport: transport)
            var action: TerminalSubmittedLineAction?
            let writes = await TelegramChannelTestSupport.capturing(terminal) {
                action = await terminal.submittedLineAction("/telegram on")
            }
            guard case .continueChat = action else {
                Issue.record("`/telegram on` asked the loop for \(String(describing: action))")
                return
            }
            #expect(writes == ["ZenCODE: /telegram requires the interactive TUI.\n"])
            #expect(terminal.sessionHost.activeChannel(in: terminal.terminalSlotID) == .primary)
            #expect(terminal.sessionHost.telegramChannel(in: terminal.terminalSlotID) == nil)
            #expect(await transport.requestCount == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    /// `/telegram off` without a `/telegram on` before tells the link
    /// stopped, as it always did, without creating a channel.
    @Test
    func telegramOffWithoutAChannelTellsTheLinkStopped() async throws {
        try await TelegramChannelTestSupport.withSupport {
            let transport = TelegramChannelTestTransport(botID: TelegramChannelTestSupport.uniqueBotID())
            let terminal = try TelegramChannelTestSupport.makeTerminal(transport: transport)
            let writes = await TelegramChannelTestSupport.capturing(terminal) {
                await terminal.handleTelegramCommand("/telegram off")
            }
            #expect(writes == ["Telegram remote control stopped.\n"])
            #expect(writes == [TelegramChannel.stoppedNoticeText])
            #expect(terminal.sessionHost.telegramChannel(in: terminal.terminalSlotID) == nil)
            #expect(await transport.requestCount == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    /// A catch-up with nothing to replay but a response in progress puts it
    /// under the catch-up title.
    @Test
    func aResponseInProgressAloneGoesUnderTheCatchUpTitle() async throws {
        try await TelegramChannelTestSupport.withSupport {
            let terminal = try TelegramChannelTestSupport.makeTerminal(
                transport: TelegramChannelTestTransport(botID: TelegramChannelTestSupport.uniqueBotID())
            )
            let writes = await TelegramChannelTestSupport.capturing(terminal) {
                await terminal.renderTelegramCatchUp(ChatTelegramCatchUp(
                    sessionID: terminal.sessionID, entries: [], liveAssistantText: "Sto scrivendo",
                    incarnationChanged: false, omittedOlderEntries: false
                ))
            }
            #expect(writes == ["\nCatch-up from Telegram:\n", "Response in progress so far:\n"])
            let output = await terminal.renderCoordinator.capturedWriteEvents().map(\.text).joined()
            let title = try #require(output.range(of: "Catch-up from Telegram:"))
            let live = try #require(output.range(of: "Sto scrivendo"))
            #expect(title.upperBound <= live.lowerBound)
            await terminal.sessionHost.shutdown()
        }
    }
}

/// A model whose prompts follow a script: streamed text, a pause until the
/// test releases it, and a `local.readFile` call. The next read of the
/// active tools can release the paused prompt and wait for its next tool
/// call (``releaseAtNextToolDescriptorsRead()``).
private actor TerminalHandoverBackend: AgentRuntimeBackend {
    enum Step: Sendable {
        case reply(String)
        case pause
        case readFile(path: String)
    }

    private var scripts: [[Step]] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var prompts: [String] = []
    private(set) var startedToolCallCount = 0
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedCount = 0
    private var releasedCount = 0
    private var releasesAtNextToolDescriptorsRead = false

    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] _, _ in self }
    }

    func enqueue(_ steps: [Step]) {
        scripts.append(steps)
    }

    /// Whether a prompt waits at a `.pause` step.
    var isPaused: Bool {
        pausedCount > releasedCount
    }

    /// Lets the prompt waiting at a `.pause` step go on.
    func release() {
        releasedCount += 1
        if !pauseWaiters.isEmpty {
            pauseWaiters.removeFirst().resume()
        }
    }

    /// The next read of the active tools (the terminal reads them while it
    /// renders a catch-up) releases the paused prompt and returns once that
    /// prompt started its next tool call.
    func releaseAtNextToolDescriptorsRead() {
        releasesAtNextToolDescriptorsRead = true
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        guard releasesAtNextToolDescriptorsRead else { return [] }
        releasesAtNextToolDescriptorsRead = false
        let started = startedToolCallCount
        release()
        let deadline = ContinuousClock.now + .seconds(5)
        while startedToolCallCount == started, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return []
    }

    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id, modelID: "test-model", workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt _: String?, allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let steps = scripts.isEmpty ? [.reply("Answer to: \(prompt)")] : scripts.removeFirst()
        var text = ""
        for (index, step) in steps.enumerated() {
            switch step {
            case let .reply(reply):
                text += reply
                await onEvent(.content(reply))
            case .pause:
                pausedCount += 1
                if releasedCount < pausedCount {
                    await withCheckedContinuation { pauseWaiters.append($0) }
                }
                try Task.checkCancellation()
            case let .readFile(path):
                let call = DirectAgentToolCall(
                    id: "read-\(index)",
                    name: "local.readFile",
                    argumentsObject: ["path": path],
                    argumentsJSON: "{}"
                )
                startedToolCallCount += 1
                await onEvent(.toolCallStarted(call))
                await onEvent(.toolCallCompleted(call, DirectAgentToolResult(
                    output: "contents", summary: "Read \(path)"
                )))
            }
        }
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID, modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt, cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: text),
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
        }
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }
}

/// A voice controller that listens forever, never speaks for real, and
/// records every text handed to it.
private actor TerminalHandoverVoiceController: TerminalVoiceController {
    nonisolated let languageCode = "it"
    private(set) var isPaused = false
    private(set) var isSpeaking = false
    private(set) var spoken: [String] = []
    private var isStopped = false

    var isActive: Bool {
        !isStopped
    }

    func start() async {}

    func stop() async {
        isStopped = true
    }

    func speak(_ text: String, rendering _: TerminalVoiceSpeechRendering) async -> Bool {
        guard !isStopped, !isPaused, !text.isEmpty else { return false }
        spoken.append(text)
        return true
    }

    func interruptPlayback() async {}

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else { return false }
        isPaused = paused
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) async {}

    func discardDictation(through id: UInt64) async {}
}
