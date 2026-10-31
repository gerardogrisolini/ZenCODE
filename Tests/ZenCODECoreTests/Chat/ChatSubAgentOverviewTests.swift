//
//  ChatSubAgentOverviewTests.swift
//  ZenCODE
//
//  The sub-agent overview as presenter state: the snapshot type and its
//  signature, the controller's publication (reserved before the snapshots are
//  read), the refresh that runs while a blocking `agent.*` call executes, the
//  channel driving them (a shared turn alone never does), and the terminal's
//  forwarders and rendering of what the controller presents.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.timeLimit(.minutes(1)))
struct ChatSubAgentOverviewTests {
    // MARK: - Overview state

    @Test
    func theOverviewCarriesTheSnapshotsTheRuntimesCurrentBatchAndTheTerminalSignature() {
        let olderBatch = UUID()
        let currentBatch = UUID()
        // The standby agent of an older wave comes first: the current batch is
        // the runtime's mark, never the array order.
        let snapshots = [
            Self.snapshot(id: "standby", status: .standby, batchID: olderBatch),
            Self.snapshot(id: "worker", batchID: currentBatch, isInCurrentWave: true),
        ]

        let overview = ChatSubAgentOverview(snapshots: snapshots)

        #expect(overview.snapshots.map(\.id) == ["standby", "worker"])
        #expect(overview.currentBatchID == currentBatch.uuidString)
        #expect(overview.signature == ChatSubAgentOverview.signature(for: snapshots))
        #expect(overview.signature == TerminalChat.subAgentOverviewSignature(snapshots))

        let empty = ChatSubAgentOverview(snapshots: [])
        #expect(empty.snapshots.isEmpty)
        #expect(empty.currentBatchID == nil)
        #expect(empty.signature.isEmpty)
    }

    // MARK: - Publication

    @Test
    func aPublicationReservesBeforeItReadsTheSnapshotsAndPresentsThemWithTheReservation() async throws {
        try await withChatHarness { harness in
            let presenter = harness.presenter
            await presenter.setRecordsSubAgentOverviews(true)
            let batch = UUID()
            let snapshots = [
                Self.snapshot(id: "first", batchID: batch, isInCurrentWave: true),
                Self.snapshot(id: "second", batchID: batch, isInCurrentWave: true),
            ]
            await harness.runtime.setSubAgentSnapshots(snapshots)
            let reservationsAtRead = Recorder<Int>()
            await harness.runtime.setSubAgentSnapshotReadHook { _ in
                await reservationsAtRead.append(await presenter.subAgentReservations.count)
            }

            await harness.controller.publishSubAgentOverviewIfChanged()

            let reservation = ChatOverviewPublication(revision: 1)
            #expect(await reservationsAtRead.values == [1])
            #expect(await harness.runtime.subAgentSnapshotReadCount == 1)
            #expect(await presenter.events == [
                .subAgentReservation(reservation),
                .subAgentOverview(
                    agentIDs: ["first", "second"],
                    signature: ChatSubAgentOverview.signature(for: snapshots),
                    currentBatchID: batch.uuidString,
                    origin: .automatic,
                    publication: reservation
                ),
            ])
        }
    }

    @Test
    func aPublicationAroundAToolCallConcernsOnlySubAgentTools() async throws {
        try await withChatHarness { harness in
            let presenter = harness.presenter
            await presenter.setRecordsSubAgentOverviews(true)
            await harness.runtime.setSubAgentSnapshots([Self.snapshot(id: "worker")])
            let controller = harness.controller

            await controller.publishSubAgentOverviewIfChanged(relatedToolName: "local.exec")
            #expect(await presenter.events.isEmpty)
            #expect(await harness.runtime.subAgentSnapshotReadCount == 0)

            await controller.publishSubAgentOverviewIfChanged(relatedToolName: "agent.wait")
            await controller.publishSubAgentOverviewIfChanged()

            #expect(await harness.runtime.subAgentSnapshotReadCount == 2)
            #expect(await presenter.subAgentOverviews.map(\.publication) == [
                ChatOverviewPublication(revision: 1),
                ChatOverviewPublication(revision: 2),
            ])
            #expect(await presenter.subAgentOverviews.allSatisfy { $0.origin == .automatic })
        }
    }

    @Test
    func aChannelThatReservesNothingIsPresentedTheOverviewAsItComes() async throws {
        try await withChatHarness { harness in
            let presenter = harness.presenter
            await presenter.setRecordsSubAgentOverviews(true)
            await presenter.setReservesSubAgentPublications(false)

            await harness.controller.publishSubAgentOverviewIfChanged()

            #expect(await presenter.subAgentReservations == [nil])
            let published = try #require(await presenter.subAgentOverviews.first)
            #expect(published.publication == nil)
            // No sub-agent: the overview is empty, which a channel shows as
            // no section.
            #expect(published.agentIDs.isEmpty)
            #expect(published.currentBatchID == nil)
        }
    }

    @Test
    func aPublicationStillReadingIsOvertakenByOneThatStartedLater() async throws {
        try await withChatHarness { harness in
            let presenter = harness.presenter
            let controller = harness.controller
            await presenter.setRecordsSubAgentOverviews(true)
            await harness.runtime.setSubAgentSnapshots([Self.snapshot(id: "older")])
            let readGate = DebounceGate()
            await harness.runtime.setSubAgentSnapshotReadHook { read in
                if read == 1 {
                    try? await readGate.sleep(.zero)
                }
            }

            // The first publication reserves and then stays in its read.
            let first = Task { await controller.publishSubAgentOverviewIfChanged() }
            await readGate.waitForEntries(1)
            #expect(await presenter.subAgentReservations == [ChatOverviewPublication(revision: 1)])

            // A later publication reserves after it and finishes first.
            await harness.runtime.setSubAgentSnapshots([Self.snapshot(id: "newer")])
            await controller.publishSubAgentOverviewIfChanged()
            await readGate.open()
            await first.value

            // The overtaken one arrives last with the older reservation, which
            // lets a channel ordering by reservation drop it.
            let overviews = await presenter.subAgentOverviews
            #expect(overviews.map(\.agentIDs) == [["newer"], ["older"]])
            #expect(overviews.map(\.publication) == [
                ChatOverviewPublication(revision: 2),
                ChatOverviewPublication(revision: 1),
            ])
        }
    }

    // MARK: - Refresh

    @Test
    func theRefreshPublishesEveryTwoSecondsUntilItStopsAndThenPublishesOnceMore() async throws {
        try await withChatHarness { harness in
            let presenter = harness.presenter
            let controller = harness.controller
            await presenter.setRecordsSubAgentOverviews(true)
            await harness.runtime.setSubAgentSnapshots([Self.snapshot(id: "worker")])
            let gate = DebounceGate()
            controller.subAgentOverviewRefresher.sleep = { try await gate.sleep($0) }
            #expect(ChatSubAgentOverviewRefresher.defaultInterval == .seconds(2))
            #expect(controller.subAgentOverviewRefresher.interval == .seconds(2))
            #expect(controller.subAgentOverviewRefreshTask == nil)

            controller.startSubAgentOverviewRefreshIfNeeded()
            #expect(controller.subAgentOverviewRefreshTask != nil)

            // Nothing is published while a tick waits.
            await gate.waitForEntries(1)
            #expect(await presenter.events.isEmpty)
            await gate.open()
            await presenter.waitForSubAgentOverviews(1)

            await gate.waitForEntries(2)
            await gate.open()
            await presenter.waitForSubAgentOverviews(2)

            // The third tick is waiting: the stop ends it, then publishes once.
            await gate.waitForEntries(3)
            await controller.stopSubAgentOverviewRefresh()

            #expect(controller.subAgentOverviewRefreshTask == nil)
            #expect(await gate.durations == [.seconds(2), .seconds(2), .seconds(2)])
            let overviews = await presenter.subAgentOverviews
            #expect(overviews.map(\.publication) == [
                ChatOverviewPublication(revision: 1),
                ChatOverviewPublication(revision: 2),
                ChatOverviewPublication(revision: 3),
            ])
            #expect(overviews.allSatisfy { $0.agentIDs == ["worker"] && $0.origin == .automatic })
            #expect(await harness.runtime.subAgentSnapshotReadCount == 3)
        }
    }

    @Test
    func startingTwiceKeepsOneRefreshAndEveryStopPublishes() async throws {
        try await withChatHarness { harness in
            let presenter = harness.presenter
            let controller = harness.controller
            await presenter.setRecordsSubAgentOverviews(true)
            let gate = DebounceGate()
            controller.subAgentOverviewRefresher.sleep = { try await gate.sleep($0) }

            controller.startSubAgentOverviewRefreshIfNeeded()
            let refresh = try #require(controller.subAgentOverviewRefreshTask)
            controller.startSubAgentOverviewRefreshIfNeeded()
            #expect(controller.subAgentOverviewRefreshTask == refresh)
            await gate.waitForEntries(1)

            await controller.stopSubAgentOverviewRefresh()
            #expect(controller.subAgentOverviewRefreshTask == nil)
            // Stopping a stopped refresh is safe and still publishes the
            // latest state, as the turn end does after every turn.
            await controller.stopSubAgentOverviewRefresh()
            #expect(controller.subAgentOverviewRefreshTask == nil)

            #expect(await gate.durations.count == 1)
            #expect(await presenter.subAgentOverviews.count == 2)
        }
    }

    @Test
    func theStopWaitsForTheTickInFlightBeforeItsFinalPublication() async throws {
        try await withChatHarness { harness in
            let presenter = harness.presenter
            let controller = harness.controller
            await presenter.setRecordsSubAgentOverviews(true)
            let gate = DebounceGate()
            let tick = HeldTick()
            controller.subAgentOverviewRefresher.sleep = { try await gate.sleep($0) }
            controller.subAgentOverviewRefresher.onTick = { await tick.hold() }

            controller.startSubAgentOverviewRefreshIfNeeded()
            await gate.waitForEntries(1)
            await gate.open()
            await tick.waitForEntry()

            let stopping = Task { await controller.stopSubAgentOverviewRefresh() }
            await tick.waitForCancellation()
            // The stop cancelled the tick and is waiting for it: it cannot
            // publish while the tick is held.
            #expect(controller.subAgentOverviewRefreshTask == nil)
            #expect(await presenter.events.isEmpty)

            await tick.release()
            await stopping.value

            // The cancelled tick publishes nothing; the stop publishes once.
            #expect(await presenter.subAgentReservations == [ChatOverviewPublication(revision: 1)])
            #expect(await presenter.subAgentOverviews.count == 1)
            #expect(await gate.durations.count == 1)
        }
    }

    // MARK: - The channel drives

    @Test
    func aSharedTurnWithASubAgentToolNeitherReadsTheSnapshotsNorReserves() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            await harness.presenter.setRecordsSubAgentOverviews(true)
            let perTurn = RecordingChatPresenter()
            await perTurn.setRecordsSubAgentOverviews(true)
            await harness.runtime.setSubAgentSnapshots([Self.snapshot(id: "worker")])
            for index in 0..<2 {
                await harness.runtime.append { call in
                    let wait = DirectAgentToolCall(
                        id: "wait-\(index)",
                        name: "agent.wait",
                        argumentsObject: [:],
                        argumentsJSON: "{}"
                    )
                    await call.onEvent(.toolCallStarted(wait))
                    await call.onEvent(.toolCallCompleted(
                        wait,
                        DirectAgentToolResult(output: "done", summary: "done")
                    ))
                    await call.onEvent(.turnEnded(.completed))
                    return DirectAgentResponse(
                        text: "Done.",
                        stopReason: "end_turn",
                        modelID: "scripted-model"
                    )
                }
            }

            // On the controller's presenter, then on a per-turn presenter as
            // the ACP bridge passes one.
            _ = try await controller.runTurn(Self.request("Wait", in: harness))
            _ = try await controller.runTurn(Self.request("Wait again", in: harness, presenter: perTurn))

            #expect(await harness.runtime.subAgentSnapshotReadCount == 0)
            #expect(controller.subAgentOverviewRefreshTask == nil)
            #expect(await harness.presenter.subAgentReservations.isEmpty)
            #expect(await harness.presenter.subAgentOverviews.isEmpty)
            #expect(await perTurn.subAgentReservations.isEmpty)
            #expect(await perTurn.subAgentOverviews.isEmpty)
            // The tool calls did reach both presenters.
            #expect(await harness.presenter.events.contains(.toolSettled("wait-0")))
            #expect(await perTurn.events.contains(.toolSettled("wait-1")))
        }
    }

    // MARK: - Terminal

    @Test @ChatSessionActor
    func theTerminalForwardsItsRefreshSeamsToTheControllersRefresher() async throws {
        let terminal = try Self.makeTerminal()
        let refresher = terminal.chatSession.subAgentOverviewRefresher
        let gate = DebounceGate()
        refresher.sleep = { try await gate.sleep($0) }
        #expect(terminal.subAgentOverviewRefreshInterval == .seconds(2))

        terminal.subAgentOverviewRefreshInterval = .milliseconds(5)
        #expect(refresher.interval == .milliseconds(5))
        terminal.onSubAgentOverviewTick = {}
        #expect(refresher.onTick != nil)
        #expect(terminal.onSubAgentOverviewTick != nil)
        terminal.onSubAgentOverviewTick = nil
        #expect(refresher.onTick == nil)

        terminal.startSubAgentOverviewRefreshIfNeeded()
        let refresh = try #require(terminal.chatSession.subAgentOverviewRefreshTask)
        #expect(terminal.subAgentOverviewRefreshTask == refresh)
        await gate.waitForEntries(1)
        #expect(await gate.durations == [.milliseconds(5)])

        await terminal.stopSubAgentOverviewRefresh()
        #expect(terminal.subAgentOverviewRefreshTask == nil)
        #expect(terminal.chatSession.subAgentOverviewRefreshTask == nil)
    }

    @Test @ChatSessionActor
    func theTerminalStartsTheRefreshForASubAgentToolAndStopsItWhenTheToolSettlesOrTheTurnFinishes() async throws {
        let terminal = try Self.makeTerminal()
        let gate = DebounceGate()
        terminal.chatSession.subAgentOverviewRefresher.sleep = { try await gate.sleep($0) }
        let presenter = terminal.chatSessionPresenter
        let result = DirectAgentToolResult(output: "done", summary: "done")
        func toolCall(_ id: String, _ name: String) -> DirectAgentToolCall {
            DirectAgentToolCall(id: id, name: name, argumentsObject: [:], argumentsJSON: "{}")
        }

        let exec = toolCall("exec", "local.exec")
        await presenter.presentToolCallStarted(exec)
        #expect(terminal.subAgentOverviewRefreshTask == nil)
        await presenter.presentToolCallSettled(exec, result: result)

        let wait = toolCall("wait", "agent.wait")
        await presenter.presentToolCallStarted(wait)
        #expect(terminal.subAgentOverviewRefreshTask != nil)
        await presenter.presentToolCallSettled(wait, result: result)
        #expect(terminal.subAgentOverviewRefreshTask == nil)

        let create = toolCall("create", "agent.create")
        await presenter.presentToolCallStarted(create)
        #expect(terminal.subAgentOverviewRefreshTask != nil)
        await presenter.turnWillFinish()
        #expect(terminal.subAgentOverviewRefreshTask == nil)
    }

    @Test @ChatSessionActor
    func theTerminalRendersAPresentedOverviewWithItsToolRowsAndDropsAnOvertakenOne() async throws {
        let terminal = try Self.makeTerminal()
        let presenter = terminal.chatSessionPresenter
        let first = try #require(await presenter.reserveSubAgentOverviewPublication())
        let second = try #require(await presenter.reserveSubAgentOverviewPublication())
        #expect(second.revision > first.revision)
        let older = ChatSubAgentOverview(snapshots: [Self.snapshot(id: "older")])
        let newer = ChatSubAgentOverview(snapshots: [Self.snapshot(id: "newer")])

        await presenter.presentSubAgentOverview(older, origin: .automatic, publication: first)
        #expect(await terminal.renderCoordinator.snapshot().lastRenderedSubAgentOverviewSignature == nil)

        await presenter.presentSubAgentOverview(newer, origin: .automatic, publication: second)
        let toolRevision = await terminal.renderCoordinator.subAgentToolPresentationSnapshot().revision
        // The terminal adds the revision of the delegated tool rows it tracks.
        #expect(
            await terminal.renderCoordinator.snapshot().lastRenderedSubAgentOverviewSignature
                == newer.signature + "\u{1C}tools:\(toolRevision)"
        )
    }

    // MARK: - Fixtures

    private static func snapshot(
        id: String,
        status: DirectSubAgentRuntime.Status = .running,
        batchID: UUID? = nil,
        isInCurrentWave: Bool = false
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: "Agent \(id)",
            role: "developer",
            overviewBatchID: batchID,
            isInCurrentOverviewWave: isInCurrentWave,
            status: status,
            pending: status == .running,
            latestOutput: nil,
            latestError: nil,
            createdAt: date,
            updatedAt: date
        )
    }

    @ChatSessionActor
    private static func request(
        _ prompt: String,
        in harness: ChatManagementHarness,
        presenter: (any ChatSessionPresenter)? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            attachments: [],
            purpose: .normal,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: harness.controller.sessionID,
                modelID: "scripted-model",
                workingDirectory: harness.workspace,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            presenter: presenter
        )
    }

    @ChatSessionActor
    private static func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "zencode-sub-agent-overview-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
    }
}

/// Values appended from another isolation domain, read back by the test.
private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }
}

/// A refresh tick held in `onTick` until the test releases it. Unlike a
/// sleep it ignores cancellation, as a tick suspended in the runtime or in the
/// channel would, and it records the cancellation so the test knows the stop
/// has cancelled the tick and is waiting for it.
private actor HeldTick {
    private var entered = false
    private var cancelled = false
    private var released = false
    private var holder: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    /// The `onTick` the refresher runs.
    nonisolated func hold() async {
        await withTaskCancellationHandler {
            await enterAndWait()
        } onCancel: {
            Task { await self.noteCancellation() }
        }
    }

    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitForCancellation() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func release() {
        released = true
        holder?.resume()
        holder = nil
    }

    private func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { holder = $0 }
    }

    private func noteCancellation() {
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
