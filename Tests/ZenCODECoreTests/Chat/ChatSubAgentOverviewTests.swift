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
}

/// Values appended from another isolation domain, read back by the test.
private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }
}
