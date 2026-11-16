//
//  TelegramChannelTurnActivityTests+HostTurns.swift
//  ZenCODE
//
//  The host tests of the Telegram turn activity suite, which run real turns
//  from the chat over a scripted backend and Bot API, with their helpers and
//  the host fixtures they open slots with.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension TelegramChannelTurnActivityTests {
    // MARK: - Turns from the chat

    /// A turn from the chat, end to end over the production wire: the
    /// reasoning as a `💭` message that an expandable blockquote covers
    /// by entity, the response, the
    /// sub-agent call's row (created, then its outcome written after the
    /// status that closed it), the `🤖 Sub-agent` status created at the
    /// call's start and edited at its settle, the response of the agent once,
    /// a new activity message for the next call with its ❌, then the
    /// outcome. Every edit targets a message the turn created.
    @Test
    func aTurnFromTheChatShowsItsThinkingToolRowsAndSubAgents() async throws {
        try await withHost { environment, slot in
            let wait = Fixtures.toolCall(id: "w1", name: "agent.wait", arguments: ["ids": ["worker"]])
            let exec = Fixtures.toolCall(id: "e1", name: "local.exec", arguments: ["command": "swift build"])
            await environment.backend.enqueue([
                .thought("Plan: wait for the worker."),
                .content("Waiting for the worker."),
                .snapshots([Fixtures.subAgent(id: "worker", status: .running, toolName: "local.exec", toolTarget: "swift test")]),
                .toolCallStarted(wait),
                .snapshots([Fixtures.subAgent(id: "worker", status: .idle, response: "Tests pass.")]),
                .toolCallCompleted(wait, Fixtures.result(elapsed: .milliseconds(420))),
                .toolCallStarted(exec),
                .toolCallCompleted(exec, Fixtures.result("exit_code: 1\nboom", summary: "exit_code: 1")),
                .content("Done."),
            ])
            let requests = try await Self.runTurnFromTheChat("Delegate it", in: slot, environment: environment)

            let sends = requests.filter { $0.method != "editMessageText" }
            #expect(sends.count == 7, "\(sends)")
            guard sends.count == 7 else { return }
            #expect(sends[0].method == "sendMessage")
            #expect(sends[0].isThinkingShape)
            #expect(sends[0].text == "💭 Plan: wait for the worker.")
            #expect(sends[1].text == "Waiting for the worker.")
            #expect(sends[2].method == "sendMessage")
            #expect(sends[3].method == "sendMessage")
            #expect(sends[3].text.hasPrefix("🤖 Sub-agent\n\n1 total"))
            #expect(sends[3].text.contains("[RUNNING]"))
            #expect(sends[4].text == "✅ Response from worker:\n\nTests pass.")
            #expect(sends[5].method == "sendMessage")
            #expect(sends[6].text.contains("ZenCODE completed"))
            #expect(sends[6].text.contains("Done."))

            let finalTexts = Self.finalTexts(requests)
            #expect(finalTexts[sends[2].messageID] == "✅ \(Fixtures.rowTitle(wait)) 420ms")
            #expect(finalTexts[sends[3].messageID]?.contains("[COMPLETED]") == true)
            #expect(finalTexts[sends[5].messageID] == "❌ \(Fixtures.rowTitle(exec))")
            let created = Set([sends[2].messageID, sends[3].messageID, sends[5].messageID])
            let edits = requests.enumerated().filter { $0.element.method == "editMessageText" }
            #expect(!edits.isEmpty)
            #expect(edits.allSatisfy { created.contains($0.element.messageID) })
            // The outcome of the sub-agent call is written after the status
            // that closed its message.
            let statusIndex = try #require(requests.firstIndex { $0.messageID == sends[3].messageID })
            let outcomeIndex = try #require(edits.first { $0.element.messageID == sends[2].messageID }?.offset)
            #expect(outcomeIndex > statusIndex)
            #expect(!requests.contains { $0.text.contains("boom") })
        }
    }

    // MARK: - Backlog (C)

    /// The backlog policy is C: a response that completed before the channel
    /// drove the slot, which the primary channel showed, never reaches the
    /// chat, and the overview of those agents, unchanged since then, creates
    /// no `🤖 Sub-agent` status, not even around an `agent.*` call or at the
    /// end of the turn; a response that completes afterwards arrives once,
    /// with the turn's status.
    @Test
    func aResponseCompletedBeforeTheChannelDroveTheSlotNeverReachesTheChat() async throws {
        try await withHost { environment, slot in
            let wait = Fixtures.toolCall(id: "w1", name: "agent.wait", arguments: ["ids": ["worker"]])
            // A first turn creates the runner's backend, which reports the
            // sub-agents; then the primary channel drives the slot while the
            // worker completes.
            _ = try await Self.runTurnFromTheChat("Hello", in: slot, environment: environment)
            _ = await slot.host.deactivateTelegram(in: slot.id)
            await environment.backend.setSnapshots([
                Fixtures.subAgent(id: "worker", status: .idle, response: "Done before the link."),
            ])
            try await Self.activateTelegramAgain(in: slot, environment: environment)

            await environment.backend.enqueue([
                .toolCallStarted(wait), .toolCallCompleted(wait, Fixtures.result()), .content("Waited."),
            ])
            let unchanged = try await Self.runTurnFromTheChat("Wait for it", in: slot, environment: environment)
            #expect(!unchanged.contains { $0.text.contains("🤖") || $0.text.contains("Response from") }, "\(unchanged)")
            #expect(unchanged.contains { $0.text.contains("Waited.") })

            await environment.backend.enqueue([
                .snapshots([Fixtures.subAgent(id: "worker", status: .idle, response: "Done after the link.")]),
                .toolCallStarted(wait), .toolCallCompleted(wait, Fixtures.result()), .content("Waited again."),
            ])
            let changed = try await Self.runTurnFromTheChat("Wait again", in: slot, environment: environment)
            #expect(changed.filter { $0.method == "sendMessage" && $0.text.hasPrefix("🤖 Sub-agent") }.count == 1, "\(changed)")
            #expect(changed.filter { $0.text == "✅ Response from worker:\n\nDone after the link." }.count == 1)
            #expect(!changed.contains { $0.text.contains("Done before the link.") })
        }
    }

    /// The publications the presenter asks the controller for around a
    /// sub-agent call (at its start, at its settle, at the end of the model
    /// work) go through the same target as its refresh: once another channel
    /// took the slot, while the turn's reporter is still alive (the switch
    /// comes before `stopDriving` and `detach`), they send nothing; only the
    /// call's own row, which the slot's presenter sent before the switch,
    /// is shown.
    @Test
    func aDirectPublicationAfterAnotherChannelTookTheSlotSendsNothing() async throws {
        try await withHost { environment, slot in
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            let presenter = channel.presenter
            let wait = Fixtures.toolCall(id: "w1", name: "agent.wait", arguments: ["ids": ["worker"]])
            // A first turn creates the runner's backend, which reports the
            // sub-agents.
            _ = try await Self.runTurnFromTheChat("Hello", in: slot, environment: environment)
            _ = await slot.host.deactivateTelegram(in: slot.id)
            #expect(!channel.drivesSlot)
            await environment.backend.setSnapshots([
                Fixtures.subAgent(id: "worker", status: .idle, response: "Late."),
            ])
            #expect(await slot.host.incarnation(in: slot.id)?.controller.runtime.subAgentSnapshots().count == 1)
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)

            await presenter.presentToolCallStarted(wait)
            await reporter.flush()
            await presenter.presentToolCallSettled(wait, result: Fixtures.result())
            await presenter.turnWillFinish()
            await reporter.flush()

            #expect(await log.effects == [.create(id: 100, text: "⏳ \(Fixtures.rowTitle(wait))")])
            #expect(slot.host.incarnation(in: slot.id)?.controller.subAgentOverviewRefreshTask == nil)
            channel.activeProgressReporter = nil
            await reporter.retire()
        }
    }

    // MARK: - Publication order

    /// A publication that a later one overtook presents nothing: the
    /// controller reserves each publication before it reads the snapshots,
    /// so the order is the one in which the reads began, not the one in
    /// which they returned. Right after the channel starts driving the slot
    /// (its backlog still being read), a tick of the primary channel's
    /// refresh begins its read first and returns last; a publication around
    /// a tool call, reserved later, reads the newer snapshots, waits for the
    /// backlog, and presents them; the tick then sends nothing, so the
    /// `🤖 Sub-agent` status never goes back to the older rows.
    @Test
    func aPublicationOvertakenWhileItReadTheSnapshotsPresentsNothing() async throws {
        try await withHost { environment, slot in
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            // A first turn creates the runner's backend, which reports the
            // sub-agents.
            _ = try await Self.runTurnFromTheChat("Hello", in: slot, environment: environment)
            let controller = try #require(slot.host.incarnation(in: slot.id)?.controller)
            let backend = environment.backend
            await channel.stopDriving()
            await backend.setSnapshots(Self.runningAgents(1))
            // The drive begins: the read of its backlog waits.
            await backend.holdSnapshotReads(true)
            channel.startDriving()
            await backend.waitUntilSnapshotReadsAreHeld(1)
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)

            // The tick, on the slot's presenter: reserved first, its read
            // waits with the older snapshots.
            await backend.setSnapshots(Self.runningAgents(2))
            let tick = Task { @ChatSessionActor in
                await controller.publishSubAgentOverviewIfChanged()
            }
            await backend.waitUntilSnapshotReadsAreHeld(2)
            // The publication around the tool call, reserved later, reads the
            // newer snapshots at once and presents them after the backlog.
            await backend.holdSnapshotReads(false)
            await backend.setSnapshots(Self.runningAgents(3))
            await backend.releaseNextSnapshotRead()
            await controller.publishSubAgentOverviewIfChanged(
                presenter: TelegramSubAgentRefreshTarget(presenter: channel.presenter)
            )
            await reporter.flush()
            // The tick's read returns last.
            await backend.releaseNextSnapshotRead()
            await tick.value
            await reporter.flush()

            let effects = await log.effects
            #expect(effects.count == 1, "\(effects)")
            if case let .create(_, text) = effects.first {
                #expect(text.hasPrefix("🤖 Sub-agent\n\n3 total"), "\(text)")
            } else {
                Issue.record("Unexpected effects: \(effects)")
            }
            channel.activeProgressReporter = nil
            await reporter.retire()
        }
    }

    // MARK: - Task graph of an ACP slot

    /// On an ACP session's slot the channel runs the controller's task-graph
    /// observer while it drives the slot, follows the slot to the controller
    /// of a new incarnation (the old one keeps none), and stops it when it
    /// stops driving the slot.
    @Test
    func theTaskGraphObserverOfAnACPSlotFollowsTheIncarnationUntilTelegramOff() async throws {
        try await withHost(identity: .acpSession("acp-\(UUID().uuidString)")) { environment, slot in
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            let first = try #require(slot.host.incarnation(in: slot.id)?.controller)
            #expect(channel.runsTaskGraphObserver)
            // `startDriving` queued the binding synchronously: its task is the
            // barrier.
            await channel.taskGraphObservationTask?.value
            #expect(Self.observesTheTaskGraph(channel, of: first))

            let outcome = await first.handleCommandLine("/sessions new", context: [])
            #expect(outcome.action == .none)
            let second = try #require(slot.host.incarnation(in: slot.id)?.controller)
            #expect(second !== first)
            // The new incarnation queued the rebinding synchronously, after
            // the binding: awaiting it awaits both.
            await channel.taskGraphObservationTask?.value
            #expect(Self.observesTheTaskGraph(channel, of: second))
            #expect(first.taskGraphObserver.observerTask == nil)

            _ = await slot.host.deactivateTelegram(in: slot.id)
            #expect(channel.taskGraphObservationTask == nil)
            #expect(channel.taskGraphObservedController == nil)
            #expect(second.taskGraphObserver.observerTask == nil)
        }
    }

    // MARK: - Helpers

    /// Whether `channel` runs the task-graph observer of `controller`.
    @ChatSessionActor
    private static func observesTheTaskGraph(
        _ channel: TelegramChannel, of controller: ChatSessionController
    ) -> Bool {
        channel.taskGraphObservedController === controller && controller.taskGraphObserver.observerTask != nil
    }

    /// `count` running sub-agents, `agent-1` to `agent-count`: their status
    /// says `count total`.
    private static func runningAgents(_ count: Int) -> [DirectSubAgentRuntime.AgentSnapshot] {
        (1 ... count).map { Fixtures.subAgent(id: "agent-\($0)", status: .running) }
    }

    /// The ending of a turn that completed with the response `text`.
    private static func completed(_ text: String) -> ChatTurnEnding {
        ChatTurnEnding(outcome: .completed(
            DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
        ))
    }

    /// Sends `prompt` from the chat and returns the requests of its turn,
    /// once its outcome was sent and the turn ended on the channel of
    /// `slot`.
    ///
    /// Nothing follows the outcome, deterministically: once the channel's
    /// task for the turn ended, the turn's reporter was flushed, retired, and
    /// revoked (its wire quiesced) and the presenter's refresh stopped, so
    /// nothing of the turn can still send.
    @ChatSessionActor
    private static func runTurnFromTheChat(
        _ prompt: String, in slot: HostSlot, environment: HostEnvironment
    ) async throws -> [TurnActivityTransport.Request] {
        let channel = try #require(slot.host.telegramChannel(in: slot.id))
        let before = await environment.transport.requests.count
        let promptsBefore = await environment.backend.prompts.count
        try await environment.transport.deliver(prompt)
        let finished = await ACPTelegramTestSupport.waitUntil(timeout: .seconds(60)) {
            await environment.transport.requests.dropFirst(before).contains { $0.text.contains("ZenCODE completed") }
        }
        #expect(finished)
        let ended = await ACPTelegramTestSupport.waitUntil(timeout: .seconds(60)) {
            await Self.turnHasEnded(on: channel)
        }
        #expect(ended)
        #expect(await environment.backend.prompts.count == promptsBefore + 1)
        return Array(await environment.transport.requests.dropFirst(before))
    }

    /// Whether no turn of `channel` runs or reports: its task ended, its
    /// reporter is gone, and the session holds no reservation.
    @ChatSessionActor
    private static func turnHasEnded(on channel: TelegramChannel) -> Bool {
        channel.activeTurnTask == nil && channel.activeProgressReporter == nil && !channel.isSessionGenerating
    }

    /// `/telegram on` again on `slot`, after a `/telegram off`: the slot is
    /// handed to the channel once more, which polls the chat again.
    @ChatSessionActor
    private static func activateTelegramAgain(in slot: HostSlot, environment: HostEnvironment) async throws {
        let polls = await environment.transport.pollCount
        try await slot.host.activateTelegram(in: slot.id)
        #expect(slot.host.telegramChannel(in: slot.id)?.drivesSlot == true)
        #expect(await ACPTelegramTestSupport.waitUntil { await environment.transport.pollCount > polls })
    }

    /// The text each message shows at the end, by its id.
    private static func finalTexts(_ requests: [TurnActivityTransport.Request]) -> [Int: String] {
        var texts: [Int: String] = [:]
        for request in requests {
            texts[request.messageID] = request.text
        }
        return texts
    }

    /// Runs `body` with a host over the scripted backend whose slot
    /// (`identity`, a window by default) Telegram drives, in a UUID support
    /// directory with paired settings.
    private func withHost(
        identity: ChatSlotIdentity = .window("telegram-turn-activity"),
        _ body: @escaping @Sendable @ChatSessionActor (HostEnvironment, HostSlot) async throws -> Void
    ) async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let environment = try HostEnvironment(root: root)
            try await Task(name: "ZenCODE.Tests.telegram-turn-activity") { @ChatSessionActor in
                let slot = try environment.openSlot(identity: identity)
                try await slot.host.activateTelegram(in: slot.id)
                _ = await ACPTelegramTestSupport.waitUntil {
                    await environment.transport.pollCount > 0
                }
                do {
                    try await body(environment, slot)
                } catch {
                    await slot.host.shutdown()
                    throw error
                }
                await slot.host.shutdown()
            }.value
        }
    }
}

// MARK: - Host fixtures

/// The scripted world of the host tests: the backend, the Bot API, and the
/// workspace.
private struct HostEnvironment: Sendable {
    let workspace: URL
    let backend = TurnActivityBackend()
    let transport = TurnActivityTransport(botID: ACPTelegramTestSupport.uniqueBotID())

    init(root: URL) throws {
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    /// A slot (`identity`) of a host over a runner on ``backend``, whose
    /// Telegram channel uses ``transport``.
    @ChatSessionActor
    func openSlot(identity: ChatSlotIdentity) throws -> HostSlot {
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
            ],
            workingDirectory: workspace
        )
        let interactionHost = ScriptedChatInteractionHost(capabilities: [.toolConsent, .textInput], decisions: [])
        let authorizer = ChatToolConsentAuthorizer(host: interactionHost)
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in await authorizer.authorize(request) },
            backendFactory: backend.factory,
            taskGraphStore: nil
        )
        let host = ChatSessionHost(
            runner: runner,
            environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
            sleepAssertionReason: "ZenCODE Telegram turn activity test"
        )
        let transport = transport
        host.telegramTransportFactory = { transport }
        let presenter = TurnActivityPrimaryPresenter()
        var descriptor = ChatSlotDescriptor(
            identity: identity,
            workingDirectory: workspace,
            presenter: presenter,
            interaction: .host(interactionHost),
            authorizer: authorizer,
            defaultOrigin: .app,
            publishesState: false
        )
        descriptor.presentTurnEnding = { ending in
            await presenter.presentTurnEnding(ending)
        }
        let incarnation = try host.openSlot(descriptor, sessionID: "turn-activity-\(UUID().uuidString)")
        return HostSlot(host: host, id: incarnation.slotID)
    }
}

@ChatSessionActor
private struct HostSlot {
    let host: ChatSessionHost
    let id: ChatSlotID
}

/// The primary channel of the host tests, which presents nothing.
@ChatSessionActor
private final class TurnActivityPrimaryPresenter: ChatSlotChannelPresenter {
    init() {}

    func turnDidMoveToChannel(_ turn: ChatMovedTurn) async {}

    func presentTurnEnding(_ ending: ChatTurnEnding) async {}
}
