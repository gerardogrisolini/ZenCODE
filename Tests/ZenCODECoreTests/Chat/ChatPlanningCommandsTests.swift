//
//  ChatPlanningCommandsTests.swift
//  ZenCODE
//
//  The planning commands of the shared controller (`/plan`, `/goal`,
//  `/review`, and the replies they wait for) against a scripted runtime and a
//  recording presenter. Every test runs in a support directory and a working
//  directory named by UUIDs, so the project's agent association, the task
//  graphs, and the saved-plan library never touch the real application state.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Chat planning commands", .serialized)
struct ChatPlanningCommandsTests {
    private typealias Fixtures = ChatTestFixtures
    private typealias Roles = AgentProfileRoleTestSupport

    /// The system profiles a project without an agent association sees.
    private static let catalog = ChatTestCatalog.hosted(
        agents: [Roles.developer, Roles.systemPlanner, Roles.systemReviewer]
    )

    /// An unapproved structured plan with two dependent points.
    private static func plan(id: String) -> TerminalSessionPlan {
        TerminalSessionPlan(
            id: id,
            originalGoal: "Fix the parser",
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

    /// A Planner discussion waiting for the operator's answer.
    private static func plannerDiscussion(goal: String) -> PlanningCommandRuntimeState {
        var state = PlanningCommandRuntimeState(goal: goal)
        state.recordPlannerOutput(
            "Planner questions\n1. Which parser?",
            agentID: "planner-1",
            revision: 1
        )
        return state
    }

    // MARK: - Gates

    @Test
    func planAndReviewRefuseWithoutTheSubAgentToolsBeforeTheEcho() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["files"]
            controller.activePlan = TerminalSessionPlan(
                originalGoal: "Fix the parser",
                consolidatedText: "1. Fix it.",
                isApproved: true
            )

            #expect(await controller.runPlanCommand(line: "/plan ship it")
                == ChatCommandOutcome(notices: [.subAgentToolsRequired(command: "/plan")]))
            #expect(await controller.runReviewCommand(line: "/review")
                == ChatCommandOutcome(notices: [.subAgentToolsRequired(command: "/review")]))
            #expect(controller.planBrainstorming == nil)
            #expect(await harness.presenter.events.isEmpty)

            // The tool group is matched without regard to case.
            controller.selection.toolKeys = ["files", "SUB-AGENTS"]
            #expect(controller.isSubAgentToolEnabled)
        }
    }

    @Test
    func planAndReviewRefuseWithoutAProfileForTheirRoleBeforeTheEcho() async throws {
        try await withChatHarness(catalog: .hosted(agents: [Roles.developer])) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["sub-agents"]
            controller.activePlan = TerminalSessionPlan(
                originalGoal: "Fix the parser",
                consolidatedText: "1. Fix it.",
                isApproved: true
            )

            #expect(await controller.runPlanCommand(line: "/plan ship it")
                == ChatCommandOutcome(notices: [.agentRoleUnavailable(.planner)]))
            #expect(await controller.runReviewCommand(line: "/review")
                == ChatCommandOutcome(notices: [.agentRoleUnavailable(.reviewer)]))

            // A Planner reply is kept pending so it can be sent again later.
            let discussion = Self.plannerDiscussion(goal: "ship it")
            controller.planBrainstorming = discussion
            #expect(await controller.pendingReplyAction(for: "The JSON one.")
                == ChatCommandOutcome(notices: [.agentRoleUnavailable(.planner)]))
            #expect(controller.planBrainstorming == discussion)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func planStartEchoesAbandonsTheOpenRequestAndStartsTheHiddenPlannerTurn() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["sub-agents"]
            let previous = Self.plan(id: "plan-kept")
            controller.activePlan = previous
            controller.pendingPlanApprovalPlanID = previous.id

            let outcome = await controller.runPlanCommand(line: "/plan ship it")

            #expect(outcome == ChatCommandOutcome(action: .startTurn(
                prompt: PlanningCommandKernel.planStartPrompt(
                    goal: "ship it",
                    planners: [Roles.systemPlanner]
                ),
                purpose: .plan(originalGoal: "ship it"),
                locksResponseLanguage: false
            )))
            #expect(controller.planBrainstorming?.goal == "ship it")
            #expect(controller.pendingPlanApprovalPlanID == nil)
            // The completed plan stays until a fresh final plan replaces it.
            #expect(controller.activePlan == previous)
            #expect(await harness.presenter.events == [.submittedCommand("/plan ship it")])

            // Without a goal the command stops before the echo.
            await harness.clearRecords()
            #expect(await controller.runPlanCommand(line: "/plan")
                == ChatCommandOutcome(notices: [.planMissingGoal]))
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    // MARK: - Saved-plan library

    @Test
    func savingListingLoadingAndDeletingGoThroughTheProjectLibrary() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            // No assistant message the library could take a plan from.
            let conversation = [Fixtures.message(.user, "Where is the bug?")]
            try await harness.startSession(conversation: conversation)
            let sessionID = controller.sessionID

            // An empty library.
            #expect(await controller.runPlanCommand(line: "/plan list")
                == ChatCommandOutcome(notices: [.noSavedPlans]))
            #expect(await controller.runPlanCommand(line: "/plan load")
                == ChatCommandOutcome(notices: [.savedPlanUnavailable]))
            #expect(await controller.runPlanCommand(line: "/plan delete all")
                == ChatCommandOutcome(notices: [.savedPlanUnavailable]))
            #expect(await controller.runPlanCommand(line: "/plan save")
                == ChatCommandOutcome(notices: [.planUnavailableForSaving]))

            // Save the active plan.
            let plan = Self.plan(id: "plan-library")
            controller.activePlan = plan
            #expect(await controller.runPlanCommand(line: "/plan save")
                == ChatCommandOutcome(notices: [.planSaved(planID: "plan-library")]))
            let library = await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace)
            #expect(library.map(\.graph.id) == ["plan-library"])
            #expect(library.first?.snapshot.savingAgentID == controller.selection.agent?.id)
            #expect(await controller.runPlanCommand(line: "/plan list")
                == ChatCommandOutcome(notices: [.savedPlans(library)]))

            // Loading needs the active plan cleared first.
            #expect(await controller.runPlanCommand(line: "/plan load")
                == ChatCommandOutcome(notices: [.activePlanAlreadyExists]))
            controller.activePlan = nil
            let savedPlan = try #require(library.first)
            let reused = PlanningCommandKernel.planPreparedForReuse(savedPlan)
            #expect(await controller.runPlanCommand(line: "/plan load")
                == ChatCommandOutcome(notices: [.savedPlanLoaded(reused)]))
            #expect(controller.activePlan == reused)
            let context = PlanningCommandKernel.savedPlanContextMessage(savedPlan, plan: reused)
            #expect(controller.history.map(\.content) == conversation.map(\.content) + [context])
            #expect(controller.transcript.last?.content == context)
            #expect(await harness.runtime.replacedHistories.last?.map(\.content)
                == controller.history.map(\.content))

            // A unique prefix deletes the plan; the active plan stays.
            #expect(await controller.runPlanCommand(line: "/plan delete")
                == ChatCommandOutcome(notices: [.planDeleteUsage]))
            #expect(await controller.runPlanCommand(line: "/plan delete plan-zzz")
                == ChatCommandOutcome(notices: [.savedPlanNotFound(availablePlanIDs: ["plan-library"])]))
            await harness.runtime.clearCalls()
            #expect(await controller.runPlanCommand(line: "/plan delete plan-lib")
                == ChatCommandOutcome(notices: [
                    .savedPlansDeleted(planIDs: ["plan-library"], activePlanAffected: true),
                ]))
            #expect(await harness.runtime.calls == [.deleteSavedTaskPlans(planIDs: ["plan-library"])])
            #expect(await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace).isEmpty)
            #expect(controller.activePlan == reused)
            #expect(try await harness.runtime.taskGraphSnapshot(sessionID: sessionID, graphID: "plan-library") == nil)

            // Every library subcommand echoes its line first.
            #expect(await harness.presenter.events == [
                "/plan list", "/plan load", "/plan delete all", "/plan save",
                "/plan save", "/plan list", "/plan load", "/plan load",
                "/plan delete", "/plan delete plan-zzz", "/plan delete plan-lib",
            ].map(RecordingChatPresenter.Event.submittedCommand))
        }
    }

    @Test
    func anOpenDiscussionOrGoalRequestBlocksSavingLoadingAndApprovingAfterTheEcho() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            controller.activePlan = Self.plan(id: "plan-blocked")

            controller.planBrainstorming = Self.plannerDiscussion(goal: "Fix the parser")
            for line in ["/plan save", "/plan load", "/plan approve"] {
                #expect(await controller.runPlanCommand(line: line)
                    == ChatCommandOutcome(notices: [.planDiscussionBlocksMutation]))
            }
            controller.planBrainstorming = nil
            controller.pendingPlanApprovalPlanID = "plan-blocked"
            #expect(await controller.runPlanCommand(line: "/plan approve")
                == ChatCommandOutcome(notices: [.planDiscussionBlocksMutation]))

            #expect(await harness.presenter.events == [
                "/plan save", "/plan load", "/plan approve", "/plan approve",
            ].map(RecordingChatPresenter.Event.submittedCommand))
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    // MARK: - Approval

    @Test
    func approvalAsksForAGoalThenActivatesTheGraphUpdatesTheLibraryAndLocksTheLanguage() async throws {
        try await withChatHarness(catalog: Self.catalog, persistsTaskGraphs: true) { harness in
            let controller = harness.controller
            let hooks = LanguageLockRecorder()
            controller.channelHooks = hooks
            try await harness.startSession()
            let sessionID = controller.sessionID
            controller.activePlan = Self.plan(id: "plan-approve")
            _ = await controller.runPlanCommand(line: "/plan save")
            await harness.clearRecords()

            #expect(await controller.runPlanCommand(line: "/plan approve")
                == ChatCommandOutcome(notices: [.planApprovalGoalPrompt]))
            #expect(controller.pendingPlanApprovalPlanID == "plan-approve")
            #expect(hooks.lockCount == 0)
            // A blank line is not a Goal.
            #expect(await controller.pendingReplyAction(for: "   ") == nil)

            let outcome = try #require(await controller.pendingReplyAction(for: "Ship the parser fix"))

            let approved = try #require(controller.activePlan)
            #expect(approved.isApproved)
            #expect(approved.originalGoal == "Ship the parser fix")
            #expect(outcome == ChatCommandOutcome(
                notices: [.planApproved],
                action: .startTurn(
                    prompt: PlanningCommandKernel.planImplementationPrompt(for: approved),
                    purpose: .normal,
                    locksResponseLanguage: false
                )
            ))
            #expect(controller.pendingPlanApprovalPlanID == nil)
            #expect(hooks.lockCount == 1)

            let graph = try #require(try await harness.runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: "plan-approve"
            ))
            #expect(graph.state == .active)
            #expect(graph.source == .plan(planID: "plan-approve"))
            #expect(graph.tasks.map(\.id) == ["plan-approve-1", "plan-approve-2"])
            #expect(graph.tasks.map(\.dependsOn) == [[], ["plan-approve-1"]])
            #expect(await harness.runtime.calls == [
                .activateTaskGraph(graphID: "plan-approve", sessionID: sessionID),
            ])
            // The library copy follows the approved Goal.
            let library = await harness.runtime.savedTaskPlans(workingDirectory: harness.workspace)
            #expect(library.map(\.snapshot.plan.originalGoal) == ["Ship the parser fix"])
            // Only the command line is echoed, never the Goal.
            #expect(await harness.presenter.events == [.submittedCommand("/plan approve")])
        }
    }

    @Test
    func failedApprovalRestoresThePreviousGraphAndKeepsThePlanUnapproved() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            let hooks = LanguageLockRecorder()
            controller.channelHooks = hooks
            try await harness.startSession()
            let sessionID = controller.sessionID
            let date = Date(timeIntervalSince1970: 1_000)
            let previous = TaskGraphSnapshot(
                id: "plan-rollback",
                source: .plan(planID: "plan-rollback"),
                state: .draft,
                revision: 1,
                tasks: [
                    TaskRecord(id: "plan-rollback-old", title: "Old task", order: 1, createdAt: date, updatedAt: date),
                ],
                createdAt: date,
                updatedAt: date
            )
            try await harness.runtime.seedTaskGraph(previous, sessionID: sessionID)
            // The new points cannot form a graph: a dependency is missing.
            controller.activePlan = TerminalSessionPlan(
                id: "plan-rollback",
                originalGoal: "Old goal",
                consolidatedText: "1. Broken.",
                points: [
                    TerminalSessionPlanPoint(
                        id: "plan-rollback-1",
                        text: "Broken",
                        dependsOn: ["missing"],
                        hasExplicitDependencies: true
                    ),
                ]
            )
            controller.pendingPlanApprovalPlanID = "plan-rollback"
            await harness.clearRecords()

            let outcome = try #require(await controller.pendingReplyAction(for: "Fix the broken plan"))

            #expect(outcome.action == .none)
            guard case let .operationFailed(description) = try #require(outcome.notices.first) else {
                Issue.record("expected operationFailed, got \(outcome.notices)")
                return
            }
            #expect(outcome.notices.count == 1)
            #expect(description != ChatPlanningCommandError.sessionOperationsUnavailable.localizedDescription)
            #expect(controller.activePlan?.isApproved == false)
            #expect(controller.activePlan?.originalGoal == "Old goal")
            #expect(controller.pendingPlanApprovalPlanID == nil)
            #expect(hooks.lockCount == 0)
            // The previous graph was removed for the new one, then restored.
            #expect(await harness.runtime.calls == [
                .restoreTaskGraph(graphID: "plan-rollback", sessionID: sessionID),
            ])
            let restored = try #require(try await harness.runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: "plan-rollback"
            ))
            #expect(restored.tasks.map(\.id) == ["plan-rollback-old"])
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func aGoalForAPlanThatWasReplacedIsRefusedAndEndsTheRequest() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            controller.activePlan = Self.plan(id: "plan-new")
            controller.pendingPlanApprovalPlanID = "plan-old"

            #expect(await controller.pendingReplyAction(for: "Ship it")
                == ChatCommandOutcome(notices: [.planUnavailableForApproval]))
            #expect(controller.pendingPlanApprovalPlanID == nil)
            #expect(controller.activePlan?.isApproved == false)
            #expect(await harness.runtime.calls.isEmpty)

            // Approving needs a plan with a text.
            controller.activePlan = nil
            #expect(await controller.runPlanCommand(line: "/plan approve")
                == ChatCommandOutcome(notices: [.planUnavailableForApproval]))
            #expect(controller.pendingPlanApprovalPlanID == nil)
        }
    }

    // MARK: - Status and clear

    @Test
    func statusReportsTheDiscussionTheGoalRequestAndTheProjectedPlan() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            try await harness.startSession()

            #expect(await controller.runPlanCommand(line: "/plan status")
                == ChatCommandOutcome(notices: [.noActivePlan]))
            controller.planBrainstorming = Self.plannerDiscussion(goal: "Fix the parser")
            #expect(await controller.runPlanCommand(line: "/plan status")
                == ChatCommandOutcome(notices: [.planClarificationActive(goal: "Fix the parser")]))

            controller.planBrainstorming = nil
            let plan = Self.plan(id: "plan-status")
            controller.activePlan = plan
            controller.pendingPlanApprovalPlanID = plan.id
            #expect(await controller.runPlanCommand(line: "/plan status")
                == ChatCommandOutcome(notices: [.planAwaitingApprovalGoal, .planStatus(plan, graph: nil)]))

            #expect(await harness.presenter.events == [
                "/plan status", "/plan status", "/plan status",
            ].map(RecordingChatPresenter.Event.submittedCommand))
        }
    }

    @Test
    func clearDropsTheDiscussionThenThePlanArchivingOnlyAGraphThatExists() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            try await harness.startSession()
            let sessionID = controller.sessionID

            #expect(await controller.runPlanCommand(line: "/plan clear")
                == ChatCommandOutcome(notices: [.noPlanToClear]))

            controller.planBrainstorming = Self.plannerDiscussion(goal: "Fix the parser")
            controller.pendingPlanApprovalPlanID = "plan-pending"
            #expect(await controller.runPlanCommand(line: "/plan clear")
                == ChatCommandOutcome(notices: [.planDiscussionCleared]))
            #expect(controller.planBrainstorming == nil)
            #expect(controller.pendingPlanApprovalPlanID == nil)

            // A plan without a graph is dropped without touching the runtime.
            controller.activePlan = Self.plan(id: "plan-no-graph")
            #expect(await controller.runPlanCommand(line: "/plan clear")
                == ChatCommandOutcome(notices: [.activePlanCleared]))
            #expect(controller.activePlan == nil)
            #expect(await harness.runtime.calls.isEmpty)

            // A plan with a graph archives it in this session.
            try await harness.runtime.seedTaskGraph(Fixtures.taskGraph(id: "plan-graph"), sessionID: sessionID)
            controller.activePlan = Self.plan(id: "plan-graph")
            #expect(await controller.runPlanCommand(line: "/plan clear")
                == ChatCommandOutcome(notices: [.activePlanCleared]))
            #expect(controller.activePlan == nil)
            #expect(await harness.runtime.calls == [
                .archiveTaskGraph(graphID: "plan-graph", sessionID: sessionID),
            ])
            #expect(try await harness.runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: "plan-graph"
            )?.state == .archived)

            #expect(await harness.presenter.events == [
                "/plan clear", "/plan clear", "/plan clear", "/plan clear",
            ].map(RecordingChatPresenter.Event.submittedCommand))
        }
    }

    @Test
    func withoutSessionOperationsTheLibraryIsEmptyAndClearingAGraphFails() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let sessionID = harness.controller.sessionID
            // A controller that only runs turns.
            let controller = ChatSessionController(
                sessionID: sessionID,
                runtime: harness.runtime,
                environment: harness.controller.environment,
                workingDirectory: harness.workspace,
                presenter: harness.presenter,
                host: harness.host,
                authorizer: harness.controller.authorizer
            )
            #expect(await controller.runPlanCommand(line: "/plan list")
                == ChatCommandOutcome(notices: [.noSavedPlans]))

            try await harness.runtime.seedTaskGraph(Fixtures.taskGraph(id: "plan-graph"), sessionID: sessionID)
            controller.activePlan = Self.plan(id: "plan-graph")
            #expect(await controller.runPlanCommand(line: "/plan clear")
                == ChatCommandOutcome(notices: [
                    .operationFailed(
                        description: ChatPlanningCommandError.sessionOperationsUnavailable.localizedDescription
                    ),
                ]))
            #expect(controller.activePlan?.id == "plan-graph")
        }
    }

    // MARK: - Pending replies

    @Test
    func aPendingReplyGoesToThePlannerBeforeTheWorkflowAndNothingWaitingLetsItThrough() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["sub-agents"]
            try await harness.startSession()

            #expect(await controller.pendingReplyAction(for: "Hello") == nil)

            var workflow = WorkflowCommandRuntimeState(goal: "Ship it", graphID: "workflow_waiting")
            workflow.armForResumedGraph()
            controller.activeWorkflow = workflow
            let discussion = Self.plannerDiscussion(goal: "Fix the parser")
            controller.planBrainstorming = discussion

            let outcome = try #require(await controller.pendingReplyAction(for: "The JSON one."))

            var answered = discussion
            let plannerReplyRecorded = answered.recordReply("The JSON one.")
            #expect(plannerReplyRecorded)
            #expect(outcome == ChatCommandOutcome(action: .startTurn(
                prompt: PlanningCommandKernel.planContinuationPrompt(
                    state: answered,
                    planners: [Roles.systemPlanner]
                ),
                purpose: .plan(originalGoal: "Fix the parser"),
                locksResponseLanguage: false
            )))
            #expect(controller.planBrainstorming == answered)
            // The workflow still waits: the reply was the Planner's.
            #expect(controller.activeWorkflow == workflow)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    // MARK: - /goal

    @Test
    func goalRefusesWithAnOpenWorkflowAndResumesItOnTheNextReply() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            try await harness.startSession()
            let sessionID = controller.sessionID

            #expect(await controller.runGoalCommand(line: "/goal")
                == ChatCommandOutcome(notices: [.workflowMissingGoal]))
            controller.activePlan = Self.plan(id: "plan-open")
            #expect(await controller.runGoalCommand(line: "/goal Ship it")
                == ChatCommandOutcome(notices: [.workflowBlockedByPlan]))
            controller.activePlan = nil
            #expect(await harness.presenter.events.isEmpty)

            // The first goal creates its workflow graph, then echoes.
            let started = await controller.runGoalCommand(line: "/goal Ship it")
            let workflow = try #require(controller.activeWorkflow)
            #expect(workflow.goal == "Ship it")
            #expect(started == ChatCommandOutcome(action: .startTurn(
                prompt: PlanningCommandKernel.workflowPrompt(goal: "Ship it", graphID: workflow.graphID),
                purpose: .workflow(originalGoal: "Ship it", graphID: workflow.graphID),
                locksResponseLanguage: false
            )))
            let graph = try #require(await controller.currentWorkflowGraph(sessionID: sessionID))
            #expect(graph.id == workflow.graphID)
            #expect(await harness.presenter.events == [.submittedCommand("/goal Ship it")])

            // A second goal is refused while the workflow is open.
            await harness.clearRecords()
            #expect(await controller.runGoalCommand(line: "/goal Something else")
                == ChatCommandOutcome(notices: [
                    .workflowAlreadyActive(graphID: workflow.graphID, pendingTaskCount: 0),
                ]))
            #expect(controller.activeWorkflow == workflow)
            #expect(await harness.presenter.events.isEmpty)

            // Not waiting for the operator: a plain line is an ordinary prompt.
            #expect(await controller.pendingReplyAction(for: "Use the main target") == nil)

            // Once the workflow asks a question, the next reply resumes it.
            let orchestrator = harness.runtime.taskOrchestrator
            let asked = try await orchestrator.updateWorkflow(
                sessionID: sessionID,
                graphID: workflow.graphID,
                state: .awaitingUser,
                message: "Which target?",
                expectedRevision: graph.revision
            )
            var waiting = workflow
            let didArm = waiting.recordCoordinatorOutput(nil, graph: asked)
            #expect(didArm)
            controller.activeWorkflow = waiting

            let resumed = try #require(await controller.pendingReplyAction(for: "Use the main target"))

            var answered = waiting
            let workflowReplyRecorded = answered.recordReply("Use the main target")
            #expect(workflowReplyRecorded)
            #expect(resumed == ChatCommandOutcome(action: .startTurn(
                prompt: PlanningCommandKernel.workflowContinuationPrompt(
                    state: answered,
                    pendingTaskCount: 0,
                    totalTaskCount: 0
                ),
                purpose: .workflow(originalGoal: "Ship it", graphID: workflow.graphID),
                locksResponseLanguage: false
            )))
            #expect(controller.activeWorkflow == answered)
            let running = try #require(await controller.currentWorkflowGraph(sessionID: sessionID))
            #expect(running.workflow?.state == .running)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func aWaitingWorkflowWhoseGraphIsGoneIsForgotten() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            try await harness.startSession()
            var workflow = WorkflowCommandRuntimeState(goal: "Ship it", graphID: "workflow_gone")
            workflow.armForResumedGraph()
            controller.activeWorkflow = workflow

            #expect(await controller.pendingReplyAction(for: "Go on") == nil)
            #expect(controller.activeWorkflow == nil)
        }
    }

    // MARK: - /review

    @Test
    func reviewWithoutChangesPlanOrGraphStopsBeforeTheEcho() async throws {
        try await withChatHarness(catalog: Self.catalog) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["sub-agents"]
            try await harness.startSession()

            #expect(controller.lastFileChangeSummary == nil)
            #expect(await controller.runReviewCommand(line: "/review the parser")
                == ChatCommandOutcome(notices: [.noChangesToReview]))
            // An unapproved plan is nothing to review either.
            controller.activePlan = Self.plan(id: "plan-unapproved")
            #expect(await controller.runReviewCommand(line: "/review")
                == ChatCommandOutcome(notices: [.noChangesToReview]))
            #expect(await harness.presenter.events.isEmpty)

            // An approved plan is reviewed with the requested scope.
            var approved = Self.plan(id: "plan-approved")
            approved.isApproved = true
            controller.activePlan = approved
            #expect(await controller.runReviewCommand(line: "/review the parser")
                == ChatCommandOutcome(action: .startTurn(
                    prompt: PlanningCommandKernel.reviewDelegationPrompt(
                        scope: "the parser",
                        reviewers: [Roles.systemReviewer],
                        changeSummary: nil,
                        approvedPlan: approved,
                        taskGraph: nil
                    ),
                    purpose: .review,
                    locksResponseLanguage: false
                )))
            #expect(await harness.presenter.events == [.submittedCommand("/review the parser")])
        }
    }
}

/// Counts the response-language locks the controller asks of the channel.
@ChatSessionActor
private final class LanguageLockRecorder: ChatSessionChannelHooks {
    private(set) var lockCount = 0

    func responseLanguageShouldLock() {
        lockCount += 1
    }
}
