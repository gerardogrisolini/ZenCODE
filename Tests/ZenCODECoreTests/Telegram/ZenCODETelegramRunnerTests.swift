//
//  ZenCODETelegramRunnerTests.swift
//  ZenCODE
//
//  `zen --telegram` without a process or real signals: the core of the mode
//  (`ZenCODETelegramRunner.run`) on a scripted Bot API and a scripted model
//  backend, stopped by a stream of its own. A successful startup hands the
//  `.telegram` slot to Telegram, logs the startup and the activation, and a
//  simulated stop ends it cleanly with status 0; Telegram not set up fails
//  before anything is built; a link that cannot start fails with status 1; a
//  prompt from the chat runs a turn whose answer reaches the Bot API, and a
//  gated tool is decided with `/allow` in the chat; a stop during the startup
//  is a clean stop, and cancels a turn in progress. Once linked, the task
//  graph an earlier session left incomplete is offered in the chat, and
//  Resume moves it into the session; a stop while that menu waits is clean.
//  The log format, the safe
//  writes, the stop-signal latch and monitor (on SIGUSR1 and SIGUSR2, which the
//  test process does not otherwise use), and the channel's behavior on the
//  `.telegram` slot (the task-graph observer, `/undo`) are covered on their
//  own. Nothing reaches the network; every test runs in a UUID support
//  directory.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// The lines a ``ZenCODETelegramLog`` wrote, in the +01:00 time zone.
private final class TelegramRunnerLogRecorder: Sendable {
    private let storage = Mutex<[String]>([])

    var log: ZenCODETelegramLog {
        ZenCODETelegramLog(timeZone: TimeZone(secondsFromGMT: 3_600)!) { [self] lines in
            storage.withLock { $0.append(lines) }
        }
    }

    /// Every line written, as written, without its newline.
    var lines: [String] {
        storage.withLock { $0 }.joined().split(separator: "\n").map(String.init)
    }

    /// The text of every line, after its timestamp; a line whose timestamp
    /// has not the expected format is kept whole, so it fails comparisons.
    var messages: [String] {
        lines.map { line in
            Self.message(of: line) ?? line
        }
    }

    /// Whether every line starts with a timestamp of the expected format.
    var everyLineIsTimestamped: Bool {
        lines.allSatisfy { Self.message(of: $0) != nil }
    }

    private static func message(of line: String) -> String? {
        guard let match = line.wholeMatch(
            of: #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+01:00 (.+)/#
        ) else { return nil }
        return String(match.output.1)
    }
}

/// Counts the calls of a factory.
private final class CallCounter: Sendable {
    private let storage = Mutex(0)

    var count: Int { storage.withLock { $0 } }

    func increment() {
        storage.withLock { $0 += 1 }
    }
}

/// The stop signals a monitor yielded, in order.
private final class ReceivedStopSignals: Sendable {
    private let storage = Mutex<[ZenCODETelegramStopSignal]>([])

    var values: [ZenCODETelegramStopSignal] { storage.withLock { $0 } }

    func append(_ signal: ZenCODETelegramStopSignal) {
        storage.withLock { $0.append(signal) }
    }
}

/// The session the mode handed to `didStart`, once it did.
@ChatSessionActor
private final class StartedSession {
    var session: ZenCODETelegramSession?
}

@ChatSessionActor
@Suite("zen --telegram runner", .serialized, .timeLimit(.minutes(2)))
struct ZenCODETelegramRunnerTests {
    private static let notSetUpMessage =
        "ZenCODE: Telegram is not set up. Run zen and use /setup to configure and pair Telegram."
    private static let hintMessage = String(ZenCODEDoctorRunner.troubleshootingHint.dropLast())

    private struct Environment: Sendable {
        let root: URL
        let workspace: URL
        let backend = ACPTelegramScriptedBackend()
        let transport = ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
        let log = TelegramRunnerLogRecorder()
        let runnerCreations = CallCounter()
        let transportCreations = CallCounter()
        /// The store of the runner's task graphs, in the support directory,
        /// where a test seeds the checkpoints of earlier sessions; `nil`, the
        /// default, keeps no task graph.
        let taskGraphStore: SessionTaskGraphStore?

        init(root: URL, persistsTaskGraphs: Bool = false) throws {
            self.root = root
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            taskGraphStore = persistsTaskGraphs ? SessionTaskGraphStore(supportDirectoryURL: root) : nil
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        func configuration() throws -> AgentConfiguration {
            try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model"),
                ],
                runMode: .telegram,
                workingDirectory: workspace
            )
        }

        /// A runner on ``backend`` with the mode's default consent, and the
        /// task-graph store ``taskGraphStore``.
        var makeSessionRunner: @Sendable (@escaping AgentToolAuthorizationHandler) -> AgentCoreSessionRunner {
            let backend = backend
            let runnerCreations = runnerCreations
            let taskGraphStore = taskGraphStore
            return { toolAuthorizationHandler in
                runnerCreations.increment()
                return AgentCoreSessionRunner(
                    defaultToolAuthorizationHandler: toolAuthorizationHandler,
                    backendFactory: backend.factory,
                    taskGraphStore: taskGraphStore
                )
            }
        }

        var transportFactory: @Sendable () -> any TelegramHTTPTransport {
            let transport = transport
            let transportCreations = transportCreations
            return {
                transportCreations.increment()
                return transport
            }
        }
    }

    /// The mode running in a task: its status once it ends, the stop the test
    /// sends it, and the session it started.
    private struct RunningMode {
        let task: Task<Int32, Never>
        let stop: AsyncStream<ZenCODETelegramStopSignal>.Continuation
        let started: StartedSession
    }

    /// Runs `body` on the chat actor in a UUID support directory holding
    /// `telegram` (none when `nil`), with a fresh environment whose runner
    /// keeps its task graphs there when `persistsTaskGraphs`.
    private nonisolated func withEnvironment(
        telegram: AgentTelegramSettingsManifest? = ACPTelegramTestSupport.pairedSettings(),
        persistsTaskGraphs: Bool = false,
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        try await ACPTelegramTestSupport.withSupportDirectory(telegram: telegram) { root in
            let environment = try Environment(root: root, persistsTaskGraphs: persistsTaskGraphs)
            try await Task(name: "ZenCODE.Tests.telegram-runner") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    /// Starts the mode in `environment`, stopped by the returned
    /// continuation.
    private static func startMode(in environment: Environment) throws -> RunningMode {
        let (stopSignals, stop) = AsyncStream.makeStream(of: ZenCODETelegramStopSignal.self)
        let started = StartedSession()
        let configuration = try environment.configuration()
        let log = environment.log.log
        let makeSessionRunner = environment.makeSessionRunner
        let transportFactory = environment.transportFactory
        let task = Task(name: "ZenCODE.Tests.telegram-runner.run") { @ChatSessionActor in
            await ZenCODETelegramRunner.run(
                configuration: configuration,
                log: log,
                stopSignals: stopSignals,
                makeSessionRunner: makeSessionRunner,
                telegramTransportFactory: transportFactory
            ) { session in
                started.session = session
            }
        }
        return RunningMode(task: task, stop: stop, started: started)
    }

    /// Starts the mode and waits until Telegram drives its slot; `nil`, with
    /// the expectation failed and the mode stopped, when it does not.
    private static func startedMode(
        in environment: Environment
    ) async throws -> (mode: RunningMode, session: ZenCODETelegramSession)? {
        let mode = try startMode(in: environment)
        let didStart = await waitUntil { mode.started.session != nil }
        guard didStart, let session = mode.started.session else {
            Issue.record("The mode did not start: \(environment.log.lines)")
            mode.stop.yield(.terminate)
            _ = await mode.task.value
            return nil
        }
        return (mode, session)
    }

    private static func waitUntil(
        attempts: Int = 1_000,
        _ condition: @ChatSessionActor () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - Startup and stop

    /// A successful startup opens the `.telegram` slot, hands it to Telegram
    /// (the channel is active and runs the task-graph observer), and logs the
    /// startup and the activation; the first stop signal ends it cleanly,
    /// with the link closed, the host shut down, and status 0.
    @Test
    func aStartedSessionIsDrivenByTelegramAndTheFirstSignalStopsItCleanly() async throws {
        try await withEnvironment { environment in
            guard let (mode, session) = try await Self.startedMode(in: environment) else { return }
            let host = session.host
            let slotID = session.slotID
            #expect(host.slotIdentity(slotID) == .telegram)
            #expect(host.activeChannel(in: slotID) == .telegram)
            #expect(host.incarnation(in: slotID)?.sessionID.hasPrefix("telegram-") == true)
            let channel = try #require(session.telegramChannel)
            #expect(channel.isActive)
            #expect(channel.observesTaskGraph)
            #expect(channel.primaryChannelDescription == "Telegram")
            #expect(channel.remoteHelpText().hasPrefix(
                "Send a message to prompt the current ZenCODE Telegram session."
            ))
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: environment.transport.botID) == 1)
            #expect(await ACPTelegramTestSupport.waitUntil { await environment.transport.pollCount > 0 })

            let startup = try #require(environment.log.messages.first)
            #expect(startup.hasPrefix("Starting ZenCODE \(agentVersion) in Telegram mode: agent "))
            #expect(startup.hasSuffix(
                ", model test-model, working directory \(environment.workspace.path)."
            ))
            #expect(Array(environment.log.messages.dropFirst()) == [
                "Telegram remote control is active.",
                "Linked chat: Test",
            ])
            #expect(environment.log.everyLineIsTimestamped)

            mode.stop.yield(.terminate)
            #expect(await mode.task.value == 0)
            #expect(!channel.isActive)
            #expect(host.isShutDown)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: environment.transport.botID) == 0)
            #expect(Array(environment.log.messages.suffix(2)) == ["Stopping (SIGTERM).", "Stopped."])
            #expect(await ACPTelegramTestSupport.waitUntil {
                await environment.transport.runningPollCount == 0
            })
        }
    }

    /// Without an enabled and paired Telegram link the mode fails at once:
    /// no runner, no host, no transport; the log tells how to set it up.
    @Test(arguments: [
        nil,
        AgentTelegramSettingsManifest(enabled: true, botToken: "123456:ABCDEF"),
    ] as [AgentTelegramSettingsManifest?])
    func telegramNotSetUpFailsBeforeOpeningTheLink(_ telegram: AgentTelegramSettingsManifest?) async throws {
        try await withEnvironment(telegram: telegram) { environment in
            let mode = try Self.startMode(in: environment)
            #expect(await mode.task.value == 1)
            #expect(environment.log.messages == [Self.notSetUpMessage, Self.hintMessage])
            #expect(environment.runnerCreations.count == 0)
            #expect(environment.transportCreations.count == 0)
            #expect(await environment.transport.pollCount == 0)
            #expect(await environment.transport.sentMessages.isEmpty)
        }
    }

    /// A link whose control service cannot start (the Bot API refuses the
    /// token) ends the mode with status 1 and the attach failure in the log;
    /// the mode does not retry, and Telegram never drove the slot.
    @Test
    func aLinkThatCannotStartEndsTheModeWithStatusOne() async throws {
        try await withEnvironment { environment in
            await environment.transport.setGetMeFails(true)
            let mode = try Self.startMode(in: environment)
            #expect(await mode.task.value == 1)
            #expect(mode.started.session == nil)
            let messages = environment.log.messages
            #expect(messages.first?.hasPrefix("Starting ZenCODE ") == true)
            #expect(messages.count >= 3)
            #expect(messages.dropFirst().first?.hasPrefix("ZenCODE: ") == true)
            #expect(messages.last == Self.hintMessage)
            #expect(!messages.contains("Telegram remote control is active."))
            #expect(environment.log.everyLineIsTimestamped)
            #expect(await environment.transport.pollCount == 0)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: environment.transport.botID) == 0)
        }
    }

    // MARK: - The chat drives the session

    /// A prompt from the chat runs a turn whose answer reaches the Bot API;
    /// neither the prompt nor the answer is logged.
    @Test
    func aPromptFromTheChatRunsATurnAndTheAnswerReachesTheBotAPI() async throws {
        try await withEnvironment { environment in
            guard let (mode, _) = try await Self.startedMode(in: environment) else { return }
            await environment.backend.enqueue([.reply("Answer from the model")])
            try await environment.transport.deliver("Hello from the chat")
            #expect(await ACPTelegramTestSupport.waitUntil {
                await environment.transport.sentTexts.contains { $0.contains("ZenCODE completed") }
            })
            #expect(await environment.backend.prompts == ["Hello from the chat"])
            #expect(await environment.transport.sentTexts.contains { $0.contains("Answer from the model") })
            let logged = environment.log.lines.joined(separator: "\n")
            #expect(!logged.contains("Hello from the chat"))
            #expect(!logged.contains("Answer from the model"))

            mode.stop.yield(.terminate)
            #expect(await mode.task.value == 0)
        }
    }

    /// The stop cancels the turn in progress instead of waiting for it to
    /// end: once the model call it waits on returns, the turn's task is
    /// cancelled and the rest of the answer is never produced.
    @Test
    func theStopCancelsTheTurnInProgress() async throws {
        try await withEnvironment { environment in
            guard let (mode, _) = try await Self.startedMode(in: environment) else { return }
            await environment.backend.enqueue([.reply("Working "), .pause, .reply("never streamed")])
            try await environment.transport.deliver("Clean the build")
            #expect(await ACPTelegramTestSupport.waitUntil { await environment.backend.isPaused })

            mode.stop.yield(.interrupt)
            #expect(await Self.waitUntil { environment.log.messages.contains("Stopping (SIGINT).") })
            // The scripted pause ignores cancellation: let the call return.
            await environment.backend.release()
            #expect(await mode.task.value == 0)
            #expect(Array(environment.log.messages.suffix(2)) == ["Stopping (SIGINT).", "Stopped."])
            #expect(await !environment.transport.sentTexts.contains { $0.contains("never streamed") })
        }
    }

    // MARK: - Task graphs of earlier sessions

    /// The title of the startup offer's menu.
    private nonisolated static let resumeMenuTitle = "Open tasks from previous sessions"

    /// Writes in `environment` the checkpoint of an earlier session
    /// `old-session` that left the graph `old-work` with 2 of its 3 tasks
    /// pending, as that process would have persisted it.
    private static func seedEarlierSessionCheckpoint(in environment: Environment) throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let tasks = (0 ..< 3).map { index in
            TaskRecord(
                id: "old-work-task-\(index)",
                title: "Task \(index)",
                order: index + 1,
                status: index == 0 ? .completed : .pending,
                execution: TaskExecutionSpec(executor: .coordinator)
            )
        }
        try #require(environment.taskGraphStore).save(
            SessionTaskGraphCheckpoint(
                sessionID: "old-session",
                currentGraphID: "old-work",
                graphs: [TaskGraphSnapshot(
                    id: "old-work", source: .manual, state: .active, tasks: tasks,
                    createdAt: date, updatedAt: date
                )]
            ),
            workingDirectory: environment.workspace
        )
    }

    /// The callback data of the buttons of a sent message, as its request
    /// body carries them, in order.
    private static func callbackData(of message: ACPTelegramSentMessage) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.rawBody.utf8)) else {
            return []
        }
        return strings(in: object).filter { $0.hasPrefix(TelegramChannel.choiceMenuCallbackPrefix) }
    }

    /// Every string of a decoded JSON value, in document order (the keys of
    /// an object sorted).
    private static func strings(in value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap { strings(in: $0) }
        }
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { strings(in: object[$0] as Any) }
        }
        return []
    }

    /// Once Telegram is linked, the task graph an earlier session left
    /// incomplete is offered in the chat, without holding `didStart`; a tap
    /// on Resume moves it into the Telegram session, which keeps its id, the
    /// chat gets the notice, and the log says which graph was resumed.
    @Test
    func theStartupOffersInTheChatTheGraphsOfEarlierSessionsAndResumeMovesOneIn() async throws {
        try await withEnvironment(persistsTaskGraphs: true) { environment in
            try Self.seedEarlierSessionCheckpoint(in: environment)
            guard let (mode, session) = try await Self.startedMode(in: environment) else { return }
            let store = try #require(environment.taskGraphStore)
            let sessionID = try #require(session.host.incarnation(in: session.slotID)?.sessionID)
            let menu = try #require(await environment.transport.waitForSentMessage {
                $0.text.hasPrefix(Self.resumeMenuTitle)
            })
            #expect(menu.text.contains("Resume\nold-work — 2 of 3 tasks pending · updated "))
            #expect(menu.text.contains("Other actions\nDelete old tasks… — "))
            #expect(menu.text.hasSuffix("Tap an option."))
            // Linked first: the activation was logged before the menu waits.
            #expect(environment.log.messages.contains("Telegram remote control is active."))
            let buttons = Self.callbackData(of: menu)
            #expect(buttons.count == 4)
            let resume = try #require(buttons.first)
            #expect(resume.hasPrefix("zencode:choice:s:"))
            #expect(resume.hasSuffix(":0"))

            try await environment.transport.deliverCallbackQuery(resume)
            #expect(await environment.transport.waitForSentMessage {
                $0.text.contains("Resumed task graph") && $0.text.contains("old-work")
            } != nil)
            #expect(await Self.waitUntil {
                environment.log.messages.contains("Resumed task graph old-work from a previous session.")
            })
            #expect(session.host.incarnation(in: session.slotID)?.sessionID == sessionID)
            #expect(try store.load(sessionID: sessionID, workingDirectory: environment.workspace)?
                .currentGraphID == "old-work")
            #expect(try store.load(sessionID: "old-session", workingDirectory: environment.workspace) == nil)

            mode.stop.yield(.terminate)
            #expect(await mode.task.value == 0)
        }
    }

    // MARK: - Signals

    /// The monitor with real signals that the test process does not use
    /// otherwise, SIGUSR1 standing for SIGTERM and SIGUSR2 for a SIGINT the
    /// parent left ignored: the ignored one stays ignored and never stops
    /// anything, the first stop signal is yielded once, and the next one logs
    /// `Forced stop.` and forces the exit (recorded here instead).
    @Test
    func theSignalMonitorStopsOnceThenForcesTheExitAndKeepsAnInheritedIgnore() async {
        _ = signal(SIGUSR2, SIG_IGN)
        let recorder = TelegramRunnerLogRecorder()
        let forcedExits = CallCounter()
        let monitor = ZenCODETelegramSignalMonitor.start(
            log: recorder.log,
            signals: [
                .init(signalNumber: SIGUSR1, stopSignal: .terminate, keepsInheritedIgnore: false),
                .init(signalNumber: SIGUSR2, stopSignal: .interrupt, keepsInheritedIgnore: true),
            ]
        ) {
            forcedExits.increment()
        }
        let received = ReceivedStopSignals()
        let reader = Task {
            for await signal in monitor.stopSignals {
                received.append(signal)
            }
        }
        defer { reader.cancel() }

        kill(getpid(), SIGUSR2)
        // A source registers asynchronously, and a signal sent before that
        // is ignored: send again, slowly, until the first one arrives.
        var delivered = false
        for _ in 0 ..< 10 where !delivered {
            kill(getpid(), SIGUSR1)
            delivered = await Self.waitUntil(attempts: 50) { !received.values.isEmpty }
        }
        #expect(delivered)
        #expect(received.values == [.terminate])

        kill(getpid(), SIGUSR1)
        #expect(await Self.waitUntil(attempts: 500) { forcedExits.count > 0 })
        #expect(recorder.messages.contains("Forced stop."))
        #expect(recorder.everyLineIsTimestamped)
        // Neither the ignored signal nor the forcing one is a second stop.
        #expect(received.values == [.terminate])
        withExtendedLifetime(monitor) {}
    }
}
