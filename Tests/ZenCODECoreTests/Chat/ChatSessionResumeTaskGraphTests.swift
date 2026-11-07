//
//  ChatSessionResumeTaskGraphTests.swift
//  ZenCODE
//
//  The startup offer of the task graphs earlier sessions left incomplete,
//  shared by every channel (`ChatSessionController.offerResumableTaskGraphs`),
//  against a scripted runtime over a real task orchestrator and a scripted
//  interaction host. The checkpoints live in a support directory and a working
//  directory named by UUIDs, never in the real application state.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Chat session task-graph resumption", .serialized)
struct ChatSessionResumeTaskGraphTests {
    // MARK: - Helpers

    private static let mainMenuTitle = "Open tasks from previous sessions"

    /// A graph with `pending` open tasks out of `total`.
    private static func graph(
        _ id: String,
        source: TaskGraphSource = .manual,
        total: Int = 1,
        pending: Int = 1,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> TaskGraphSnapshot {
        let tasks = (0 ..< total).map { index in
            TaskRecord(
                id: "\(id)-task-\(index)",
                title: "Task \(index)",
                order: index + 1,
                status: index < total - pending ? .completed : .pending,
                execution: TaskExecutionSpec(executor: source.isWorkflow ? .subAgent : .coordinator)
            )
        }
        return TaskGraphSnapshot(
            id: id,
            source: source,
            state: .active,
            tasks: tasks,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    /// Writes the checkpoint an earlier session `sessionID` left, as that
    /// process would have persisted it.
    @ChatSessionActor
    private static func seedCheckpoint(
        _ graphs: [TaskGraphSnapshot],
        sessionID: String,
        in harness: ChatManagementHarness
    ) throws {
        try SessionTaskGraphStore(supportDirectoryURL: harness.support).save(
            SessionTaskGraphCheckpoint(
                sessionID: sessionID,
                currentGraphID: graphs.first?.id,
                graphs: graphs
            ),
            workingDirectory: harness.workspace
        )
    }

    @ChatSessionActor
    private static func checkpoint(
        _ sessionID: String,
        in harness: ChatManagementHarness
    ) throws -> SessionTaskGraphCheckpoint? {
        try SessionTaskGraphStore(supportDirectoryURL: harness.support).load(
            sessionID: sessionID,
            workingDirectory: harness.workspace
        )
    }

    /// The items of every main menu the host presented, in order.
    private static func mainMenus(
        _ interactions: [ScriptedChatInteractionHost.Interaction]
    ) -> [[ChatChoiceItem]] {
        interactions.compactMap { interaction in
            if case let .chooseOne(title, items, _) = interaction, title == mainMenuTitle {
                return items
            }
            return nil
        }
    }

    private static func resumeID(_ sessionID: String, _ graphID: String) -> String {
        "resume:\(sessionID)/\(graphID)"
    }

    // MARK: - Resume

    @Test
    func resumingMovesTheChosenGraphIntoTheControllersSession() async throws {
        try await withChatHarness(
            hostCapabilities: [.singleChoice, .multipleChoice],
            persistsTaskGraphs: true
        ) { harness in
            let controller = harness.controller
            let sessionID = controller.sessionID
            try Self.seedCheckpoint(
                [Self.graph("old-work", total: 3, pending: 2)],
                sessionID: "old-session",
                in: harness
            )
            await harness.host.answerChooseOne(Self.resumeID("old-session", "old-work"))

            let outcome = await controller.offerResumableTaskGraphs()

            #expect(outcome.resumedGraph?.id == "old-session/old-work")
            #expect(outcome.notices == [
                .taskGraphResumed(graphID: "old-work", pendingTaskCount: 2, isWorkflow: false),
            ])
            #expect(outcome.notices.map(ChatSessionNoticeText.text(for:)) == [
                "Resumed task graph \"old-work\" from a previous session (2 tasks pending). "
                    + "Use /tasks to review it.\n",
            ])
            // The session keeps its id and now owns the graph.
            #expect(controller.sessionID == sessionID)
            let current = try await harness.runtime.taskOrchestrator.graphSnapshot(sessionID: sessionID)
            #expect(current?.id == "old-work")
            #expect(current?.state == .active)
            #expect(try Self.checkpoint(sessionID, in: harness)?.currentGraphID == "old-work")
            #expect(try Self.checkpoint("old-session", in: harness) == nil)
            #expect(controller.activeWorkflow == nil)
            #expect(await harness.runtime.calls == [
                .adoptResumableTaskGraph(id: "old-session/old-work", intoSessionID: sessionID),
            ])
            // The menu as the terminal drew it: `(x)` on the first resume entry.
            let interactions = await harness.host.interactions
            #expect(interactions.count == 1)
            guard case let .chooseOne(title, items, selectedID) = interactions.first else {
                Issue.record("the offer should present the main menu")
                return
            }
            #expect(title == Self.mainMenuTitle)
            #expect(selectedID == Self.resumeID("old-session", "old-work"))
            #expect(items.map(\.title) == ["old-work", "Delete old tasks…", "Start fresh"])
            #expect(items.map(\.group) == ["Resume", "Other actions", "Other actions"])
            #expect(items.first?.detail == "2 of 3 tasks pending · updated "
                + ChatSessionNoticeText.timestampText(Date(timeIntervalSince1970: 1_000)))
            // The notices are returned, not presented.
            #expect(await harness.presenter.notices.isEmpty)
        }
    }

    @Test
    func resumingAWorkflowArmsItsContinuationOnTheSameGraph() async throws {
        try await withChatHarness(
            hostCapabilities: [.singleChoice, .multipleChoice],
            persistsTaskGraphs: true
        ) { harness in
            let controller = harness.controller
            try Self.seedCheckpoint(
                [Self.graph("workflow_old", source: .workflow)],
                sessionID: "old-session",
                in: harness
            )
            await harness.host.answerChooseOne(Self.resumeID("old-session", "workflow_old"))

            let outcome = await controller.offerResumableTaskGraphs()

            #expect(outcome.notices == [
                .taskGraphResumed(graphID: "workflow_old", pendingTaskCount: 1, isWorkflow: true),
            ])
            #expect(outcome.notices.map(ChatSessionNoticeText.text(for:)) == [
                "Resumed workflow \"workflow_old\" from a previous session (1 task pending). "
                    + "Your next message continues it on the same task graph; "
                    + "use /tasks to review or /tasks clear to stop it.\n",
            ])
            #expect(controller.activeWorkflow?.graphID == "workflow_old")
            #expect(controller.activeWorkflow?.isAwaitingReply == true)
            #expect(controller.activeWorkflow?.pendingSignal == .resumedGraph)
        }
    }

    // MARK: - Start fresh and cancel

    @Test
    func startingFreshOrCancellingLeavesEveryCheckpointAsItWas() async throws {
        for answer in [ChatSessionController.resumableTaskGraphStartFreshChoiceID, nil] {
            try await withChatHarness(
                hostCapabilities: [.singleChoice, .multipleChoice],
                persistsTaskGraphs: true
            ) { harness in
                try Self.seedCheckpoint([Self.graph("old-work")], sessionID: "old-session", in: harness)
                await harness.host.answerChooseOne(answer)

                let outcome = await harness.controller.offerResumableTaskGraphs()

                #expect(outcome == .none)
                #expect(await harness.runtime.calls.isEmpty)
                #expect(await harness.host.interactions.count == 1)
                #expect(try Self.checkpoint("old-session", in: harness)?.graphs.map(\.id) == ["old-work"])
                #expect(try await harness.runtime.taskOrchestrator.graphSnapshot(
                    sessionID: harness.controller.sessionID
                ) == nil)
            }
        }
    }

    // MARK: - Delete

    @Test
    func deletingAsksWhichGraphsAndOffersTheRemainingOnesAgain() async throws {
        try await withChatHarness(
            hostCapabilities: [.singleChoice, .multipleChoice],
            persistsTaskGraphs: true
        ) { harness in
            try Self.seedCheckpoint(
                [Self.graph("graph-a", updatedAt: Date(timeIntervalSince1970: 2_000))],
                sessionID: "old-a",
                in: harness
            )
            try Self.seedCheckpoint([Self.graph("graph-b")], sessionID: "old-b", in: harness)
            await harness.host.answerChooseOne(ChatSessionController.resumableTaskGraphDeleteChoiceID)
            await harness.host.answerChooseMany(["old-b/graph-b"])
            await harness.host.answerChooseOne(ChatSessionController.resumableTaskGraphStartFreshChoiceID)

            let outcome = await harness.controller.offerResumableTaskGraphs()

            #expect(outcome.resumedGraph == nil)
            #expect(outcome.notices == [.oldTaskGraphsDeleted(count: 1)])
            #expect(outcome.notices.map(ChatSessionNoticeText.text(for:)) == ["Deleted 1 old task graph.\n"])
            #expect(await harness.runtime.calls == [.removeResumableTaskGraphs(ids: ["old-b/graph-b"])])
            #expect(try Self.checkpoint("old-b", in: harness) == nil)
            #expect(try Self.checkpoint("old-a", in: harness)?.graphs.map(\.id) == ["graph-a"])

            let interactions = await harness.host.interactions
            #expect(interactions.count == 3)
            guard interactions.count == 3,
                  case let .chooseMany(title, items, selectedIDs) = interactions[1] else {
                Issue.record("the deletion should ask with a checkbox menu")
                return
            }
            #expect(title == "Delete old tasks")
            #expect(selectedIDs.isEmpty)
            #expect(items.map(\.id) == ["old-a/graph-a", "old-b/graph-b"])
            #expect(items.map(\.title) == ["graph-a", "graph-b"])
            #expect(items.last?.detail == "1 pending · updated "
                + ChatSessionNoticeText.timestampText(Date(timeIntervalSince1970: 1_000)))
            // Offered again without the deleted graph.
            #expect(Self.mainMenus(interactions).map { $0.map(\.id) } == [
                [Self.resumeID("old-a", "graph-a"), Self.resumeID("old-b", "graph-b"), "delete", "fresh"],
                [Self.resumeID("old-a", "graph-a"), "delete", "fresh"],
            ])
        }
    }

    // MARK: - What is offered

    @Test
    func theControllersOwnSessionIsNeverOffered() async throws {
        try await withChatHarness(
            hostCapabilities: [.singleChoice, .multipleChoice],
            persistsTaskGraphs: true
        ) { harness in
            try Self.seedCheckpoint([Self.graph("mine")], sessionID: harness.controller.sessionID, in: harness)

            // Only its own graph: nothing to offer, nothing asked.
            #expect(await harness.controller.offerResumableTaskGraphs() == .none)
            #expect(await harness.host.interactions.isEmpty)

            try Self.seedCheckpoint([Self.graph("old-work")], sessionID: "old-session", in: harness)
            _ = await harness.controller.offerResumableTaskGraphs()
            #expect(Self.mainMenus(await harness.host.interactions).map { $0.map(\.title) } == [
                ["old-work", "Delete old tasks…", "Start fresh"],
            ])
        }
    }

    @Test
    func theSessionsOfTheHostsOtherSlotsAreNeverOffered() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-chat-resume-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable @ChatSessionActor in
            let store = SessionTaskGraphStore(supportDirectoryURL: support)
            let configuration = try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: [ChatTestFixtures.developer],
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model"),
                ],
                workingDirectory: workspace
            )
            // No session is ever created, so the runner needs no backend.
            let host = ChatSessionHost(
                runner: AgentCoreSessionRunner(backendFactory: nil, taskGraphStore: store),
                environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
                sleepAssertionReason: "ZenCODE resume test"
            )
            func descriptor(_ name: String, host interactionHost: ScriptedChatInteractionHost) -> ChatSlotDescriptor {
                ChatSlotDescriptor(
                    identity: .window(name),
                    workingDirectory: configuration.workingDirectory,
                    presenter: RecordingChatPresenter(),
                    interaction: .host(interactionHost),
                    authorizer: ChatToolConsentAuthorizer(host: interactionHost),
                    publishesState: false
                )
            }
            let firstHost = ScriptedChatInteractionHost(capabilities: [.singleChoice])
            let secondHost = ScriptedChatInteractionHost(capabilities: [.singleChoice])
            _ = try host.openSlot(descriptor("first", host: firstHost), sessionID: "first-window")
            let second = try host.openSlot(descriptor("second", host: secondHost), sessionID: "second-window")
            #expect(host.liveSessionIDs() == ["first-window", "second-window"])

            for (sessionID, graphID) in [("first-window", "running-elsewhere"), ("old-session", "old-work")] {
                try store.save(
                    SessionTaskGraphCheckpoint(
                        sessionID: sessionID,
                        currentGraphID: graphID,
                        graphs: [Self.graph(graphID)]
                    ),
                    workingDirectory: configuration.workingDirectory
                )
            }

            let outcome = await second.controller.offerResumableTaskGraphs()

            #expect(outcome == .none)
            #expect(await firstHost.interactions.isEmpty)
            #expect(Self.mainMenus(await secondHost.interactions).map { $0.map(\.id) } == [
                [Self.resumeID("old-session", "old-work"), "delete", "fresh"],
            ])
            await host.shutdown()
        }
    }

    // MARK: - Failures and hosts that cannot ask

    @Test
    func aFailedResumptionIsReportedAndTheMenuOfferedAgain() async throws {
        try await withChatHarness(
            hostCapabilities: [.singleChoice, .multipleChoice],
            persistsTaskGraphs: true
        ) { harness in
            try Self.seedCheckpoint([Self.graph("old-work")], sessionID: "old-session", in: harness)
            await harness.runtime.failNextAdoptResumableTaskGraph(
                ScriptedChatRuntime.ScriptedFailure(message: "disk full")
            )
            await harness.host.answerChooseOne(Self.resumeID("old-session", "old-work"))
            await harness.host.answerChooseOne(ChatSessionController.resumableTaskGraphStartFreshChoiceID)

            let outcome = await harness.controller.offerResumableTaskGraphs()

            #expect(outcome.resumedGraph == nil)
            #expect(outcome.notices == [.taskGraphResumeFailed(graphID: "old-work", description: "disk full")])
            #expect(outcome.notices.map(ChatSessionNoticeText.text(for:)) == ["Could not resume old-work: disk full\n"])
            #expect(Self.mainMenus(await harness.host.interactions).count == 2)
            #expect(try Self.checkpoint("old-session", in: harness)?.graphs.map(\.id) == ["old-work"])
            #expect(try await harness.runtime.taskOrchestrator.graphSnapshot(
                sessionID: harness.controller.sessionID
            ) == nil)
        }
    }

    @Test
    func aControllerWithoutSessionManagementOffersNothing() async throws {
        try await withChatHarness(
            hostCapabilities: [.singleChoice, .multipleChoice],
            persistsTaskGraphs: true
        ) { harness in
            try Self.seedCheckpoint([Self.graph("old-work")], sessionID: "old-session", in: harness)
            let turnOnly = ChatSessionController(
                sessionID: "turn-only",
                runtime: harness.runtime,
                environment: harness.controller.environment,
                workingDirectory: harness.workspace,
                presenter: harness.presenter,
                host: harness.host,
                authorizer: ChatToolConsentAuthorizer(host: harness.host)
            )

            #expect(await turnOnly.offerResumableTaskGraphs() == .none)
            #expect(await harness.host.interactions.isEmpty)
        }
    }

    // MARK: - Notices

    @Test
    func theNoticesArePresentedInOrderOnTheSystemChannel() async throws {
        let notices: [ChatSessionNotice] = [
            .oldTaskGraphsDeleted(count: 1),
            .oldTaskGraphsDeleteFailed(description: "locked"),
            .taskGraphResumeFailed(graphID: "graph-a", description: "gone"),
            .taskGraphResumed(graphID: "graph-b", pendingTaskCount: 3, isWorkflow: false),
        ]
        #expect(notices.allSatisfy { $0.channel == .system })
        #expect(notices.map(ChatSessionNoticeText.text(for:)) == [
            "Deleted 1 old task graph.\n",
            "Could not delete old tasks: locked\n",
            "Could not resume graph-a: gone\n",
            "Resumed task graph \"graph-b\" from a previous session (3 tasks pending). Use /tasks to review it.\n",
        ])

        try await withChatHarness { harness in
            await harness.controller.presentSessionNotices(notices)
            #expect(await harness.presenter.notices == notices)
        }
    }
}
