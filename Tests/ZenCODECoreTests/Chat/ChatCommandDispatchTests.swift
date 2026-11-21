//
//  ChatCommandDispatchTests.swift
//  ZenCODE
//
//  The shared dispatcher of slash commands (`handleCommandLine(_:context:)`):
//  unknown, hidden, and channel-only commands, the routing of every shared
//  command onto its operation, the order of the channel's command steps
//  against the runtime and the closing notices, the ACP planning policy
//  (one case for each behavior ACP keeps), and the command fence that a
//  cancellation trips in the middle of `/goal` and of an approval.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Chat command dispatch", .serialized)
struct ChatCommandDispatchTests {
    typealias Fixtures = ChatTestFixtures
    private typealias Roles = AgentProfileRoleTestSupport

    /// The system profiles a project without an agent association sees.
    static let catalog = ChatTestCatalog.hosted(
        agents: [Roles.developer, Roles.systemPlanner, Roles.systemReviewer]
    )

    /// The shared commands with three channel commands: one always visible,
    /// one hidden as unknown without the Builder agent, and one hidden with
    /// its own message.
    static let registry = ChatCommandRegistry(
        shared: ChatCommandRegistry.sharedDescriptors,
        channel: [
            (after: "/help", descriptors: [
                ChatCommandDescriptor(
                    command: "/quit",
                    summary: "close",
                    help: "/quit closes the session.",
                    scope: .channel
                ),
                ChatCommandDescriptor(
                    command: "/builder-only",
                    summary: "builder",
                    help: "/builder-only is for the Builder.",
                    scope: .channel,
                    availability: .builderAgent
                ),
                ChatCommandDescriptor(
                    command: "/builder-feature",
                    summary: "builder feature",
                    help: "/builder-feature is for the Builder.",
                    scope: .channel,
                    availability: .builderAgent,
                    hiddenMessage: "ZenCODE: only with the Builder agent.\n"
                ),
            ]),
        ]
    )

    /// An unapproved structured plan with two dependent points.
    private static func plan(id: String, goal: String = "Fix the parser") -> TerminalSessionPlan {
        TerminalSessionPlan(
            id: id,
            originalGoal: goal,
            consolidatedText: "1. Read the parser.\n2. Fix it.",
            createdAt: Date(timeIntervalSince1970: 1_000),
            points: [
                TerminalSessionPlanPoint(id: "\(id)-1", text: "Read the parser", hasExplicitDependencies: true),
                TerminalSessionPlanPoint(
                    id: "\(id)-2",
                    text: "Fix it",
                    dependsOn: ["\(id)-1"],
                    hasExplicitDependencies: true
                ),
            ]
        )
    }

    /// The ACP policy, with a `/review` prompt that names its inputs.
    private static func acpPolicy(
        savingAgent: AgentProfile? = nil,
        fallbackHistory: [AgentRuntimeMessage] = []
    ) -> ChatPlanningCommandPolicy {
        .acp(
            savingAgent: savingAgent,
            fallbackHistory: fallbackHistory,
            reviewPrompt: { request in
                "ACP REVIEW scope=\(request.scope) plan=\(request.approvedPlan?.id ?? "none") "
                    + "graph=\(request.taskGraph?.id ?? "none") reviewers=\(request.reviewers.count)"
            }
        )
    }

    // MARK: - ACP policy

    @Test
    func acpReviewNeverRefusesForLackOfChangesAndBuildsItsOwnPrompt() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            // ACP checks its own grant: the selection's tool groups do not count.
            controller.selection.toolKeys = []

            let outcome = await controller.runReviewCommand(
                line: "/review@zen focus on parsing",
                policy: Self.acpPolicy()
            )
            #expect(outcome == ChatCommandOutcome(action: .startTurn(
                prompt: "ACP REVIEW scope=focus on parsing plan=none graph=none reviewers=1",
                purpose: .review,
                locksResponseLanguage: false
            )))

            // A plan whose text is blank is no approved plan for ACP.
            controller.activePlan = TerminalSessionPlan(
                id: "blank-plan",
                originalGoal: "Fix it",
                consolidatedText: "   ",
                isApproved: true
            )
            let blank = await controller.runReviewCommand(line: "/review", policy: Self.acpPolicy())
            #expect(blank == ChatCommandOutcome(action: .startTurn(
                prompt: "ACP REVIEW scope= plan=none graph=none reviewers=1",
                purpose: .review,
                locksResponseLanguage: false
            )))

            // The terminal refuses the same `/review` without changes.
            controller.activePlan = nil
            controller.selection.toolKeys = ["sub-agents"]
            #expect(await controller.runReviewCommand(line: "/review")
                == ChatCommandOutcome(notices: [.noChangesToReview]))
        }
    }

    @Test
    func acpPlanSaveStoresTheActivePlanWithItsQueueAndRefusesASequenceWithABlankPlan() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            let first = Self.plan(id: "acp-first")
            let second = Self.plan(id: "acp-second", goal: "Validate the parser")

            // A blank plan anywhere in the sequence makes it unsaveable.
            controller.activePlan = first
            controller.queuedPlans = [
                TerminalSessionPlan(id: "acp-blank", originalGoal: "Goal", consolidatedText: " "),
            ]
            #expect(await controller.runPlanCommand(line: "/plan save", policy: Self.acpPolicy())
                == ChatCommandOutcome(notices: [.planUnavailableForSaving]))
            #expect(await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace).isEmpty)

            controller.queuedPlans = [second]
            let outcome = await controller.runPlanCommand(
                line: "/plan save",
                policy: Self.acpPolicy(savingAgent: Roles.systemReviewer)
            )
            #expect(outcome == ChatCommandOutcome(notices: [
                .planSequenceSaved(planIDs: ["acp-first", "acp-second"]),
            ]))
            #expect(controller.activePlan == first)
            #expect(controller.queuedPlans == [second])
            let library = await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace)
            #expect(library.map(\.graph.id) == ["acp-second", "acp-first"])
            #expect(library.allSatisfy { $0.snapshot.savingAgentName == Roles.systemReviewer.name })
        }
    }

    @Test
    func acpPlanSavePromotesEveryPlanOfTheLatestAnswerInTheFallbackHistory() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            let answer = """
            Piano 1/2: Parser

            Specifiche concordate
            - Keep the public API.

            Implementation plan
            1. Read the parser.
               Dependencies: none

            Piano 2/2: Validation

            Specifiche concordate
            - Cover the regression.

            Implementation plan
            1. Add the regression test.
               Dependencies: none
            """
            let outcome = await controller.runPlanCommand(
                line: "/plan save",
                policy: Self.acpPolicy(fallbackHistory: [
                    Fixtures.message(.user, "Ship the parser fix"),
                    Fixtures.message(.assistant, answer),
                ])
            )

            let active = try #require(controller.activePlan)
            let next = try #require(controller.queuedPlans.first)
            #expect(controller.queuedPlans.count == 1)
            #expect(outcome == ChatCommandOutcome(notices: [.planSequenceSaved(planIDs: [active.id, next.id])]))
            #expect(active.originalGoal == "Piano 1/2: Parser — Ship the parser fix")
            #expect(next.originalGoal == "Piano 2/2: Validation — Ship the parser fix")
            let library = await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace)
            #expect(library.map(\.graph.id) == [next.id, active.id])
        }
    }

    @Test
    func acpPlanLoadExtendsTheRuntimeSessionsHistory() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: [Fixtures.message(.user, "controller copy")])
            let runtimeHistory = [
                Fixtures.message(.user, "client history"),
                Fixtures.message(.assistant, "client answer"),
            ]
            await harness.runtime.setSessionHistory(runtimeHistory, sessionID: controller.sessionID)
            let plan = Self.plan(id: "library-plan")
            controller.activePlan = plan
            _ = await controller.runPlanCommand(line: "/plan save")
            controller.activePlan = nil

            let outcome = await controller.runPlanCommand(line: "/plan load", policy: Self.acpPolicy())

            guard case let .savedPlanLoaded(loaded)? = outcome.notices.first else {
                Issue.record("Expected the loaded plan, got \(outcome.notices)")
                return
            }
            #expect(loaded.id == plan.id)
            let replaced = try #require(await harness.runtime.replacedHistories.last)
            #expect(replaced.dropLast().map(\.content) == runtimeHistory.map(\.content))
            #expect(replaced.count == runtimeHistory.count + 1)
            // The controller's own copy is left alone.
            #expect(controller.history.map(\.content) == ["controller copy"])
            #expect(controller.activePlan == loaded)
        }
    }

    @Test
    func acpProjectsARestoredWorkflowBeforeTheSharedReply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-dispatch-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            let fixture = try await Self.makeACPFixture(sessionID: "acp-dispatch-projection")
            let orchestrator = await fixture.bridge.sessionRunner.taskOrchestrator
            let graph = try await orchestrator.createGraph(
                sessionID: fixture.sessionID, id: "workflow-restored", source: .workflow, state: .active,
                tasks: [], originalGoal: "Keep the restored goal"
            )
            _ = try await orchestrator.updateWorkflow(
                sessionID: fixture.sessionID, graphID: graph.id, state: .awaitingUser,
                message: "Which file first?", expectedRevision: graph.revision
            )
            // The command state knows no workflow: the shared reply alone
            // would leave the message an ordinary prompt.
            let controller = try #require(
                await fixture.bridge.chatSessionControllerForTesting(sessionID: fixture.sessionID)
            )
            #expect(await fixture.bridge.workflowStateForTesting(sessionID: fixture.sessionID) == nil)
            #expect(await controller.workflowContinuationReplyAction(for: "Start with main.swift") == nil)

            try await fixture.bridge.prompt(id: .number(1), params: [
                "sessionId": fixture.sessionID, "prompt": "Start with main.swift",
            ])

            let prompts = await fixture.backend.recordedPrompts()
            let continuation = try #require(prompts.first { $0.contains("Continue the goal workflow") })
            #expect(continuation.contains("Goal: Keep the restored goal"))
            #expect(continuation.contains("Start with main.swift"))
            #expect(fixture.wire.stopReason(for: 1) == "end_turn")
        }
    }

    // MARK: - Fence

    @Test
    func aGoalSupersededAfterCreatingItsGraphRemovesTheGraph() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            let fence = controller.beginCommandFence(sessionID: controller.sessionID)
            // The cancellation lands between the graph's creation and the
            // workflow's state.
            await harness.presenter.setSubmittedCommandHook { _ in
                controller.cancelActiveTurn()
            }

            let outcome = await controller.runGoalCommand(line: "/goal ship it", fence: fence)

            #expect(outcome == ChatCommandOutcome())
            #expect(!controller.isCurrent(fence))
            #expect(await harness.presenter.events == [.submittedCommand("/goal ship it")])
            #expect(controller.activeWorkflow == nil)
            let graph = try await harness.runtime.taskGraphSnapshot(sessionID: controller.sessionID, graphID: nil)
            #expect(graph == nil)
        }
    }

    @Test
    func anApprovalSupersededAfterActivatingTheGraphRollsItBack() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            let plan = Self.plan(id: "approved-plan")
            controller.activePlan = plan
            controller.pendingPlanApprovalPlanID = plan.id
            // A previous graph with the plan's ID, which the approval replaces.
            let previous = Fixtures.taskGraph(id: plan.id)
            try await harness.runtime.seedTaskGraph(previous, sessionID: controller.sessionID)
            let fence = controller.beginCommandFence(sessionID: controller.sessionID)
            await harness.runtime.setTaskGraphActivationHook { _ in
                controller.cancelActiveTurn()
            }

            let outcome = await controller.pendingReplyAction(
                for: "Ship the parser",
                fence: fence,
                policy: Self.acpPolicy()
            )

            #expect(outcome == ChatCommandOutcome())
            #expect(!controller.isCurrent(fence))
            // The plan stays unapproved; the Goal request was consumed before
            // the graph changed, as ACP always did.
            #expect(controller.activePlan == plan)
            #expect(controller.pendingPlanApprovalPlanID == nil)
            // The new graph is gone and the previous one is back.
            let restored = try #require(
                try await harness.runtime.taskGraphSnapshot(sessionID: controller.sessionID, graphID: plan.id)
            )
            #expect(restored.tasks.map(\.id) == previous.tasks.map(\.id))
            #expect(restored.source == previous.source)
            #expect(await harness.callNames() == ["activateTaskGraph", "restoreTaskGraph"])
        }
    }

    // MARK: - Support

    /// An ACP bridge over a scripted backend with one installed session.
    private static func makeACPFixture(sessionID: String) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: DispatchACPWire,
        sessionID: String
    ) {
        let workingDirectory = AppStorageDirectory.appSupportDirectoryURL()
            .appendingPathComponent(sessionID, isDirectory: true)
        let backend = ScriptedACPCommandBackend()
        let wire = DispatchACPWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model"),
            ],
            runMode: .acp,
            workingDirectory: workingDirectory
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: { _, _ in backend }
        )
        let sessionConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "Chat command dispatch test",
            cacheKey: nil,
            history: [],
            allowedToolNames: nil
        )
        try await bridge.sessionRunner.createSession(configuration: sessionConfiguration)
        await bridge.installTestSession(sessionConfiguration)
        return (bridge, backend, wire, sessionID)
    }
}

/// The JSON-RPC messages an ACP bridge writes.
private final class DispatchACPWire: Sendable {
    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    func stopReason(for requestID: Int) -> String? {
        storage.withLock { values in
            values.compactMap { value -> String? in
                guard let object = value.objectValue,
                      object["id"] == .number(Double(requestID)) else {
                    return nil
                }
                return object["result"]?.objectValue?["stopReason"]?.stringValue
            }.first
        }
    }
}
