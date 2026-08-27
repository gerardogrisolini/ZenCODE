//
//  PlanCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct PlanCommandTests {
    @Test
    func planCommandIsVisibleWithStandardCommands() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)

        #expect(commands.contains("/plan"))
    }

    @Test
    func subAgentsCommandIsRemovedFromVisibleCommands() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)

        #expect(!commands.contains("/subagents"))
        #expect(!TerminalChat.isKnownSlashCommand("/subagents"))
    }

    @Test
    func planCommandRequiresExplicitGoalArgument() throws {
        let descriptor = try #require(
            TerminalChat.visibleCommandDescriptors(
                builderAgentEnabled: false,
                telegramEnabled: false
            ).first(where: { $0.command == "/plan" })
        )

        #expect(descriptor.requiresArgument)
        #expect(descriptor.help.contains("/plan <goal>"))
        #expect(descriptor.help.contains("/plan save"))
        #expect(descriptor.help.contains("/plan load"))
        #expect(descriptor.help.contains("/plan list"))
        #expect(descriptor.help.contains("/plan delete"))
        #expect(descriptor.help.contains("/plan status"))
        #expect(descriptor.help.contains("/plan approve"))
        #expect(descriptor.help.contains("start implementation immediately"))
        #expect(descriptor.help.contains("/plan clear"))
        #expect(!descriptor.help.contains("/plan [goal]"))
    }

    @Test
    func savedPlanDeletionTargetResolvesAllExactAndUniquePrefix() {
        let planIDs = ["plan-aaaa1111", "plan-aaaa2222", "plan-bbbb3333"]

        #expect(
            TerminalChat.savedPlanDeletionTarget("ALL", in: planIDs)
                == .ids(planIDs)
        )
        #expect(
            TerminalChat.savedPlanDeletionTarget("plan-bbbb3333", in: planIDs)
                == .ids(["plan-bbbb3333"])
        )
        #expect(
            TerminalChat.savedPlanDeletionTarget("plan-bbbb", in: planIDs)
                == .ids(["plan-bbbb3333"])
        )
        #expect(
            TerminalChat.savedPlanDeletionTarget("plan-aaaa", in: planIDs)
                == .ambiguous(matches: ["plan-aaaa1111", "plan-aaaa2222"])
        )
        #expect(
            TerminalChat.savedPlanDeletionTarget("plan-zzzz", in: planIDs)
                == .notFound
        )
        #expect(
            TerminalChat.savedPlanDeletionTarget("   ", in: planIDs)
                == .notFound
        )
    }

    @Test
    func planDeleteTargetExtractsTargetFromRawArgument() {
        #expect(TerminalChat.planDeleteTarget(from: "delete plan-abc") == "plan-abc")
        #expect(TerminalChat.planDeleteTarget(from: "DELETE   plan-abc ") == "plan-abc")
        #expect(TerminalChat.planDeleteTarget(from: "delete") == nil)
        #expect(TerminalChat.planDeleteTarget(from: "delete   ") == nil)
    }

    @Test
    func loadableSavedPlanSkipsCompletedLibraryEntries() {
        let draftPlan = TerminalSessionPlan(
            id: "plan-draft-0001",
            originalGoal: "Reusable draft",
            consolidatedText: "Still to implement."
        )
        let completedPlan = TerminalSessionPlan(
            id: "plan-done-0002",
            originalGoal: "Already implemented",
            consolidatedText: "Done."
        )
        let now = Date()
        func savedPlan(
            for plan: TerminalSessionPlan,
            state: TaskGraphState
        ) -> SavedTaskPlan {
            SavedTaskPlan(
                librarySessionID: "saved-plans-test",
                graph: TaskGraphSnapshot(
                    id: plan.id,
                    source: .plan(planID: plan.id),
                    state: state,
                    tasks: [TaskRecord(id: "task", title: "Task", order: 1)],
                    savedPlan: TaskGraphSavedPlan(plan: plan),
                    createdAt: now,
                    updatedAt: now
                ),
                snapshot: TaskGraphSavedPlan(plan: plan)
            )
        }

        let newestFirst = [
            savedPlan(for: completedPlan, state: .completed),
            savedPlan(for: draftPlan, state: .draft),
        ]
        #expect(
            TerminalChat.loadableSavedPlan(from: newestFirst)?.graph.id
                == draftPlan.id
        )
        #expect(
            TerminalChat.loadableSavedPlan(
                from: [savedPlan(for: completedPlan, state: .completed)]
            ) == nil
        )
        #expect(TerminalChat.loadableSavedPlan(from: []) == nil)
    }

    @Test
    func savedPlansListMessageRendersShortIDStatusAndCounts() {
        let now = Date()
        let savedPlans = [
            SavedTaskPlan(
                librarySessionID: "saved-plans-test",
                graph: TaskGraphSnapshot(
                    id: "plan-aaaaaaaa-1111",
                    source: .plan(planID: "plan-aaaaaaaa-1111"),
                    state: .draft,
                    tasks: [
                        TaskRecord(id: "task-1", title: "One", order: 1),
                        TaskRecord(id: "task-2", title: "Two", order: 2),
                    ],
                    savedPlan: TaskGraphSavedPlan(
                        plan: TerminalSessionPlan(
                            id: "plan-aaaaaaaa-1111",
                            originalGoal: "Improve the terminal | renderer",
                            consolidatedText: "Plan body."
                        )
                    ),
                    createdAt: now,
                    updatedAt: now
                ),
                snapshot: TaskGraphSavedPlan(
                    plan: TerminalSessionPlan(
                        id: "plan-aaaaaaaa-1111",
                        originalGoal: "Improve the terminal | renderer",
                        consolidatedText: "Plan body."
                    )
                )
            ),
        ]

        let message = TerminalChat.savedPlansListMessage(for: savedPlans)
        #expect(message.contains("## Saved plans"))
        #expect(message.contains("**Total:** 1"))
        #expect(message.contains("`plan-aaaaaaaa`"))
        #expect(message.contains("`draft`"))
        #expect(message.contains("0/2"))
        #expect(message.contains("Improve the terminal \\| renderer"))
        #expect(message.contains("/plan delete <plan|prefix|all>"))
        // Round trip: the short id rendered by the list must resolve in the
        // deletion target resolver without any user retyping.
        #expect(
            TerminalChat.savedPlanDeletionTarget(
                "plan-aaaaaaaa",
                in: savedPlans.map(\.graph.id)
            ) == .ids(["plan-aaaaaaaa-1111"])
        )
    }

    @Test
    func planDeleteSuccessMessageCountsDeletionsAndNotesActivePlan() {
        #expect(
            TerminalChat.planDeleteSuccessMessage(
                deletedPlanIDs: ["plan-x"],
                activePlanAffected: false
            ) == "Deleted saved plan `plan-x`.\n"
        )
        let bulkMessage = TerminalChat.planDeleteSuccessMessage(
            deletedPlanIDs: ["plan-x", "plan-y"],
            activePlanAffected: true
        )
        #expect(bulkMessage.contains("Deleted 2 saved plans."))
        #expect(bulkMessage.contains("use /plan clear to discard it"))
        #expect(
            TerminalChat.planDeleteSuccessMessage(
                deletedPlanIDs: [],
                activePlanAffected: false
            ).contains("no saved plans were deleted")
        )
    }

    @Test
    func planStatusRendersStructuredItemsWithoutDelegation() async throws {
        let terminal = try makeTerminal()
        terminal.selectedToolKeys.remove("sub-agents")
        let plan = TerminalSessionPlan(
            originalGoal: "Track implementation",
            consolidatedText: "Implement and validate.",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-1",
                    text: "Implement | command",
                    status: .completed
                ),
                TerminalSessionPlanPoint(
                    id: "plan-2",
                    text: "Run tests",
                    status: .inProgress
                ),
            ]
        )
        terminal.activePlan = plan

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan STATUS")))
        #expect(terminal.activePlan == plan)

        let table = TerminalChat.planStatusTable(for: plan)
        #expect(table.contains("| # | Plan item | Status |"))
        #expect(table.contains("| 1 | Implement \\| command | `completed` |"))
        #expect(table.contains("| 2 | Run tests | `in_progress` |"))
        #expect(table.contains("**Overall status:** `in_progress`"))

        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 100,
            supportsHyperlinks: false
        )
        let rendered = formatter.consume(table) + formatter.finish()
        #expect(!rendered.contains("|---:"))
        #expect(rendered.contains("Plan item"))
        #expect(rendered.contains("in_progress"))
    }

    @Test
    func planStatusDerivesFailureFromAnActiveGraph() {
        let now = Date(timeIntervalSince1970: 10)
        let plan = TerminalSessionPlan(
            id: "plan-failure",
            originalGoal: "Track failure",
            consolidatedText: "Implement.",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(id: "plan-failure-1", text: "Implement")
            ]
        )
        let graph = TaskGraphSnapshot(
            id: plan.id,
            source: .plan(planID: plan.id),
            state: .active,
            tasks: [
                TaskRecord(
                    id: "plan-failure-1",
                    title: "Implement",
                    order: 1,
                    status: .failed,
                    createdAt: now,
                    updatedAt: now
                )
            ],
            createdAt: now,
            updatedAt: now
        )
        let projected = TerminalChat.plan(plan, applying: graph)
        let table = TerminalChat.planStatusTable(for: projected, graph: graph)

        #expect(table.contains("**Overall status:** `failed`"))
        #expect(table.contains("| 1 | Implement | `failed` |"))
    }

    @Test
    func planStatusKeepsStatusesReadableWhenItemsAreLong() {
        let longItem = Array(
            repeating: "Implement the detailed compatibility and validation requirement",
            count: 16
        ).joined(separator: " ")
        let plan = TerminalSessionPlan(
            originalGoal: "Track a long implementation",
            consolidatedText: "Implement and validate.",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-1",
                    text: longItem,
                    status: .completed
                ),
                TerminalSessionPlanPoint(
                    id: "plan-2",
                    text: longItem,
                    status: .inProgress
                ),
            ]
        )
        var formatter = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 90,
            supportsHyperlinks: false
        )

        let rendered = TerminalANSIText.stripANSI(
            formatter.consume(TerminalChat.planStatusTable(for: plan)) + formatter.finish()
        )
        let tableRows = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("│") }

        #expect(tableRows.contains { $0.contains("completed") })
        #expect(tableRows.contains { $0.contains("in_progress") })
        #expect(tableRows.contains { $0.contains("…") })
        #expect(tableRows.allSatisfy { TerminalANSIText.visibleWidth($0) <= 90 })
    }

    @Test
    func planStatusWithoutActivePlanDoesNotRequireSubAgents() async throws {
        let terminal = try makeTerminal()
        terminal.selectedToolKeys.remove("sub-agents")

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan status")))
        #expect(terminal.activePlan == nil)
    }

    @Test
    func barePlanCommandStopsBeforeDelegatingToPlanner() async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-plan-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )
        terminal.selectedToolKeys.insert("sub-agents")

        let action = await terminal.handlePlanCommand("/plan")

        switch action {
        case .continueChat:
            break
        case .runHiddenPrompt(_, _):
            Issue.record("Bare /plan should not create a hidden delegation prompt")
        default:
            Issue.record("Bare /plan should only continue the chat after reporting the missing goal")
        }
    }

    @Test
    func planSavePersistsTodoDerivedDraftAndLoadRehydratesANewSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanSaveTests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let source = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: store)
        )
        try await source.sessionRunner.taskOrchestrator.registerSession(
            id: source.sessionID,
            workingDirectory: workingDirectory
        )
        let createdAt = Date(timeIntervalSince1970: 100)
        source.activePlan = TerminalSessionPlan(
            id: "plan-handoff",
            originalGoal: "Carry the plan into another session",
            consolidatedText: "1. Inspect\n2. Implement",
            createdAt: createdAt,
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-handoff-1",
                    text: "Inspect",
                    status: .completed,
                    hasExplicitDependencies: true
                ),
                TerminalSessionPlanPoint(
                    id: "plan-handoff-2",
                    text: "Implement",
                    status: .inProgress,
                    dependsOn: ["plan-handoff-1"],
                    hasExplicitDependencies: true
                ),
            ]
        )

        #expect(isContinueChat(await source.handlePlanCommand("/plan save")))

        let storedPlans = await source.sessionRunner.savedTaskPlans(
            workingDirectory: workingDirectory
        )
        let stored = try #require(storedPlans.first)
        #expect(stored.librarySessionID == SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: workingDirectory
        ))
        #expect(stored.graph.state == .draft)
        #expect(stored.graph.tasks.map(\.title) == ["Inspect", "Implement"])
        #expect(stored.graph.tasks[1].dependsOn == ["plan-handoff-1"])
        #expect(stored.snapshot.plan.id == source.activePlan?.id)
        #expect(stored.snapshot.plan.consolidatedText == source.activePlan?.consolidatedText)
        #expect(stored.snapshot.plan.isApproved == false)
        #expect(stored.snapshot.plan.points.map(\.status) == [.pending, .pending])
        #expect(await source.sessionRunner.resumableTaskGraphCheckpoints(
            workingDirectory: workingDirectory
        ).isEmpty)

        let sourceSessionID = source.sessionID
        await source.startNewSession()
        #expect(source.sessionID != sourceSessionID)
        #expect(source.activePlan == nil)
        #expect(isContinueChat(await source.handlePlanCommand("/plan load")))

        let loaded = try #require(source.activePlan)
        #expect(loaded.id == "plan-handoff")
        #expect(loaded.originalGoal == "Carry the plan into another session")
        #expect(loaded.consolidatedText == "1. Inspect\n2. Implement")
        #expect(loaded.createdAt == createdAt)
        #expect(loaded.isApproved == false)
        #expect(loaded.points.map(\.status) == [.pending, .pending])
        #expect(loaded.points[1].dependsOn == ["plan-handoff-1"])
        #expect(source.activeSessionHistory.last?.role == .user)
        #expect(source.activeSessionHistory.last?.content.contains("[Saved plan handoff]") == true)
        #expect(source.activeSessionHistory.last?.content.contains("1. Inspect") == true)
    }

    @Test
    func planSaveCanPromoteTextOnlyResponseAndApprovalMaterializesItAfterLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanSaveFallbackTests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = AgentCoreSessionRunner(
            taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
        )
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: workingDirectory
            ),
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        terminal.selectedAgent = AgentProfile(
            id: "architect-agent",
            name: "Architect"
        )
        terminal.activeSessionTranscript = [
            AgentRuntimeMessage(role: .user, content: "Design the migration"),
            AgentRuntimeMessage(role: .assistant, content: "First inspect, then migrate and test."),
        ]

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan save")))

        let promoted = try #require(terminal.activePlan)
        #expect(promoted.originalGoal == "Design the migration")
        #expect(promoted.consolidatedText == "First inspect, then migrate and test.")
        #expect(promoted.points.isEmpty)
        let stored = try #require(await runner.savedTaskPlans(
            workingDirectory: workingDirectory
        ).first)
        #expect(stored.snapshot.plan == promoted)
        #expect(stored.graph.tasks.isEmpty)
        #expect(stored.snapshot.savingAgentName == "Architect")
        let context = TerminalChat.savedPlanContextMessage(stored, plan: promoted)
        #expect(context.contains("Saved by agent: Architect"))
        #expect(!context.contains("Source agent:"))

        await terminal.startNewSession()
        #expect(terminal.activePlan == nil)
        #expect(!terminal.didLockResponseLanguage)
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan load")))
        #expect(terminal.activePlan?.id == promoted.id)
        #expect(terminal.activePlan?.points.isEmpty == true)

        let approval = await terminal.handlePlanCommand("/plan approve")
        guard case let .runHiddenPrompt(prompt, purpose) = approval else {
            Issue.record("Approval should materialize a loaded text-only plan")
            return
        }
        #expect(purpose == .normal)
        #expect(terminal.didLockResponseLanguage)
        #expect(prompt.contains("session response language from the system prompt"))
        #expect(prompt.contains("Do not answer in English merely because this internal prompt is in English."))

        let taskID = "\(promoted.id)-implementation"
        let graph = try #require(try await runner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: promoted.id
        ))
        #expect(graph.state == .active)
        #expect(graph.source == .plan(planID: promoted.id))
        #expect(graph.tasks.map(\.id) == [taskID])
        #expect(graph.tasks.map(\.title) == ["Implement approved plan: Design the migration"])
        #expect(terminal.activePlan?.isApproved == true)
        #expect(terminal.activePlan?.points.map(\.id) == [taskID])
    }

    @Test
    func planSaveWithoutAPlanDoesNotCreateCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanSaveEmptyTests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentCoreSessionRunner(
            taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
        )
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: workingDirectory
            ),
            stdinIsTerminal: false,
            sessionRunner: runner
        )

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan save")))
        #expect(terminal.activePlan == nil)
        #expect(await runner.savedTaskPlans(workingDirectory: workingDirectory).isEmpty)
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan load")))
        #expect(terminal.activePlan == nil)
    }

    @Test
    func planCommandWithGoalRunsHiddenDelegationPrompt() async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-plan-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )
        terminal.selectedToolKeys.insert("sub-agents")

        let action = await terminal.handlePlanCommand("/plan fix the planner command")

        switch action {
        case let .runHiddenPrompt(prompt, purpose):
            #expect(prompt.contains("Planning goal requested by the user: fix the planner command"))
            #expect(prompt.contains("agent.create"))
            #expect(prompt.contains("\"Dependencies\" entry"))
            #expect(prompt.contains("DAG with the minimum safe edges"))
            #expect(prompt.contains("must not chain items merely because"))
            #expect(prompt.contains("never add an edge merely"))
            #expect(prompt.contains("parallelism has no useful benefit"))
            #expect(purpose == .plan(originalGoal: "fix the planner command"))
        case .runPrompt(_):
            Issue.record("/plan <goal> should keep the generated delegation prompt hidden")
        default:
            Issue.record("/plan <goal> should start the planning delegation prompt")
        }
    }

    @Test
    func sharedCoordinatorCommandParserCoversPlanGoalAndReview() {
        #expect(
            CoordinatorCommandParser.parse(" /PLAN   replace routing ")
                == .plan(.start(goal: "replace routing"))
        )
        #expect(CoordinatorCommandParser.parse("/plan") == .plan(.missingGoal))
        #expect(CoordinatorCommandParser.parse("/plan CLEAR") == .plan(.clear))
        #expect(
            CoordinatorCommandParser.parse("/plan delete plan-abcd")
                == .plan(.delete(target: "plan-abcd"))
        )
        #expect(CoordinatorCommandParser.parse("/goal ship it") == .goal("ship it"))
        #expect(CoordinatorCommandParser.parse("/review") == .review(""))
        #expect(
            CoordinatorCommandParser.parse("/review@zencode_bot focus on races")
                == .review("focus on races")
        )
        #expect(
            CoordinatorCommandParser.parse("/plan@zencode_bot telegram goal")
                == .plan(.start(goal: "telegram goal"))
        )
        #expect(CoordinatorCommandParser.parse("/help") == nil)
        #expect(CoordinatorCommandParser.parse("@planner answer") == nil)
    }

    @Test
    func planningRuntimeStateTransitionsAcrossMultipleQuestionBlocks() throws {
        var state = PlanningCommandRuntimeState(
            goal: "  clarify shared routing  ",
            collectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        )
        #expect(state.goal == "clarify shared routing")
        #expect(!state.isAwaitingReply)
        let acceptedEarlyReply = state.recordReply("too early")
        #expect(!acceptedEarlyReply)

        state.recordPlannerOutput(
            "# Planner questions\n1. First decision?",
            agentID: "planner-1",
            revision: 4
        )
        #expect(state.isAwaitingReply)
        let acceptedFirstReply = state.recordReply("Use the recommended choice.")
        #expect(acceptedFirstReply)
        #expect(state.exchanges.count == 1)
        #expect(!state.isAwaitingReply)

        state.recordPlannerOutput(
            "Planner questions:\n1. Remaining decision?",
            agentID: "planner-1",
            revision: 5
        )
        let acceptedSecondReply = state.recordReply("Keep it runtime-only.")
        #expect(acceptedSecondReply)
        #expect(state.exchanges.map(\.userReply) == [
            "Use the recommended choice.",
            "Keep it runtime-only.",
        ])
    }

    @Test
    func plannerFreshnessReusesAvailableAuthorAndAllowsRecreationOnlyAfterClosure() throws {
        func snapshot(
            id: String,
            status: DirectSubAgentRuntime.Status,
            revision: UInt64,
            output: String
        ) -> DirectSubAgentRuntime.AgentSnapshot {
            DirectSubAgentRuntime.AgentSnapshot(
                id: id,
                rootSessionID: "planning-session",
                name: PlanningCommandKernel.planAuthorAgentName,
                role: AgentProfileStore.plannerAgentName,
                profileID: AgentProfileStore.plannerAgentID.uuidString,
                status: status,
                pending: false,
                latestOutput: output,
                latestOutputRevision: revision,
                latestError: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision + 1))
            )
        }

        var state = PlanningCommandRuntimeState(goal: "reuse planner")
        state.recordPlannerOutput(
            "Planner questions\n1. Choice?",
            agentID: "planner-existing",
            revision: 2
        )
        let available = snapshot(
            id: "planner-existing",
            status: .idle,
            revision: 2,
            output: "Planner questions\n1. Choice?"
        )
        let availableBaseline = PlannerTurnBaseline(
            state: state,
            snapshots: [available],
            rootSessionID: "planning-session"
        )
        let improperReplacement = snapshot(
            id: "planner-replacement",
            status: .idle,
            revision: 1,
            output: "Replacement output"
        )
        #expect(PlanningCommandKernel.freshPlannerSnapshot(
            from: [available, improperReplacement],
            baseline: availableBaseline,
            rootSessionID: "planning-session"
        ) == nil)

        let updatedExisting = snapshot(
            id: "planner-existing",
            status: .idle,
            revision: 3,
            output: "Specifiche concordate\n\nImplementation plan\n1. Implement"
        )
        #expect(PlanningCommandKernel.freshPlannerSnapshot(
            from: [updatedExisting, improperReplacement],
            baseline: availableBaseline,
            rootSessionID: "planning-session"
        )?.id == "planner-existing")

        let closedBaseline = PlannerTurnBaseline(
            state: state,
            snapshots: [snapshot(
                id: "planner-existing",
                status: .closed,
                revision: 2,
                output: "Planner questions\n1. Choice?"
            )],
            rootSessionID: "planning-session"
        )
        #expect(PlanningCommandKernel.freshPlannerSnapshot(
            from: [improperReplacement],
            baseline: closedBaseline,
            rootSessionID: "planning-session"
        )?.id == "planner-replacement")
    }

    @Test
    func sharedKernelRejectsTextTaskMismatchAndInvalidDependencyBootstrap() {
        let text = """
        Specifiche concordate
        - Keep compatibility.

        Implementation plan
        1. Implement shared routing.
           Dependencies: none
        2. Validate every frontend.
           Dependencies: 1
        """
        let coherent = [
            TerminalSessionPlanPoint(
                id: "plan-coherent-1",
                text: "Implement shared routing.",
                dependsOn: [],
                hasExplicitDependencies: true
            ),
            TerminalSessionPlanPoint(
                id: "plan-coherent-2",
                text: "Validate every frontend.",
                dependsOn: ["plan-coherent-1"],
                hasExplicitDependencies: true
            ),
        ]
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: coherent
        ))
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: [coherent[0]]
        ))

        var wrongText = coherent
        wrongText[1] = TerminalSessionPlanPoint(
            id: "plan-coherent-2",
            text: "Publish a release instead.",
            dependsOn: ["plan-coherent-1"],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: wrongText
        ))

        var wrongDependencies = coherent
        wrongDependencies[1] = TerminalSessionPlanPoint(
            id: "plan-coherent-2",
            text: "Validate every frontend.",
            dependsOn: [],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: wrongDependencies
        ))

        var terminalStatus = coherent
        terminalStatus[0] = TerminalSessionPlanPoint(
            id: "plan-coherent-1",
            text: "Implement shared routing.",
            status: .completed,
            dependsOn: [],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: terminalStatus
        ))

        var mixedToken = coherent
        mixedToken[1] = TerminalSessionPlanPoint(
            id: "plan-other-2",
            text: "Validate every frontend.",
            dependsOn: ["plan-coherent-1"],
            hasExplicitDependencies: true
        )
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: mixedToken
        ))
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: "1. Implement shared routing.",
            points: [coherent[0]]
        ))
        for invalidDependency in ["2", "1, 1", "3"] {
            #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
                text: text.replacingOccurrences(
                    of: "Dependencies: 1",
                    with: "Dependencies: \(invalidDependency)"
                ),
                points: coherent
            ))
        }

        let symbolText = """
        Specifiche concordate
        - Preserve concrete identifiers.

        Implementation plan
        1. Update `foo_bar.swift` and preserve C# behavior.
           Dependencies: none
        """
        let symbolPoint = TerminalSessionPlanPoint(
            id: "plan-symbol-1",
            text: "Update `foo_bar.swift` and preserve C# behavior.",
            dependsOn: [],
            hasExplicitDependencies: true
        )
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: symbolText,
            points: [symbolPoint]
        ))
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: symbolText,
            points: [TerminalSessionPlanPoint(
                id: "plan-symbol-1",
                text: "Update foobar.swift and preserve C behavior.",
                dependsOn: [],
                hasExplicitDependencies: true
            )]
        ))

        let cyclic = [
            TerminalSessionPlanPoint(
                id: "plan-cycle-1",
                text: "Implement shared routing.",
                dependsOn: ["plan-cycle-2"],
                hasExplicitDependencies: true
            ),
            TerminalSessionPlanPoint(
                id: "plan-cycle-2",
                text: "Validate every frontend.",
                dependsOn: ["plan-cycle-1"],
                hasExplicitDependencies: true
            ),
        ]
        #expect(!PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: text,
            points: cyclic
        ))
    }

    @Test
    func plannerQuestionHistoryCannotBecomeASavedPlanCandidate() {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "/plan clarify behavior"),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Planner questions\n1. Which behavior should be used?"
            ),
        ]
        #expect(PlanningCommandKernel.planFromLatestAssistantMessage(
            in: messages
        ) == nil)
    }

    @Test
    func newPlanReplacesOnlyTheDiscussionAndClearCancelsIt() async throws {
        let terminal = try makeTerminal()
        terminal.activePlan = TerminalSessionPlan(
            id: "plan-existing",
            originalGoal: "existing goal",
            consolidatedText: "Existing completed draft"
        )
        var discussion = PlanningCommandRuntimeState(goal: "old goal")
        discussion.recordPlannerOutput(
            "Planner questions\n1. Old question?",
            agentID: "missing-old-planner",
            revision: 1
        )
        terminal.planBrainstorming = discussion

        let oldCollectionID = discussion.collectionID
        guard case .runHiddenPrompt = await terminal.handlePlanCommand("/plan new goal") else {
            Issue.record("A new /plan goal should start a fresh hidden turn")
            return
        }
        #expect(terminal.activePlan?.id == "plan-existing")
        #expect(terminal.planBrainstorming?.goal == "new goal")
        #expect(terminal.planBrainstorming?.collectionID != oldCollectionID)

        // A late failure/cancellation from the abandoned turn is fenced by its
        // collection id and cannot clear the replacement discussion.
        await terminal.abandonPlanBrainstorming(
            expectedCollectionID: oldCollectionID
        )
        #expect(terminal.planBrainstorming?.goal == "new goal")

        terminal.activePlan = nil
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan clear")))
        #expect(terminal.planBrainstorming == nil)
    }

    @Test
    func successfulPlanOutputIsRecordedAndReplacementRequiresApprovalAgain() async throws {
        let terminal = try makeTerminal()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        #expect(terminal.recordPlanIfNeeded(
            responseText: "  First consolidated plan  ",
            purpose: .plan(originalGoal: " first goal "),
            createdAt: firstDate,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "First item")
            ]
        ))
        #expect(terminal.activePlan == TerminalSessionPlan(
            id: terminal.activePlan?.id,
            originalGoal: "first goal",
            consolidatedText: "First consolidated plan",
            createdAt: firstDate,
            isApproved: false,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "First item")
            ]
        ))

        let approvalAction = await terminal.handlePlanCommand("/plan approve")
        #expect(terminal.activePlan?.isApproved == true)
        guard case let .runHiddenPrompt(prompt, purpose) = approvalAction else {
            Issue.record("/plan approve should start implementation immediately")
            return
        }
        #expect(purpose == .normal)
        #expect(prompt.contains("Implement the active approved plan now"))
        #expect(prompt.contains("First consolidated plan"))
        #expect(prompt.contains("Complete every task in the graph"))
        #expect(prompt.contains("Do not recreate or replace the approved plan"))

        #expect(terminal.recordPlanIfNeeded(
            responseText: "Second consolidated plan",
            purpose: .plan(originalGoal: "second goal"),
            createdAt: secondDate
        ))
        #expect(terminal.activePlan?.originalGoal == "second goal")
        #expect(terminal.activePlan?.consolidatedText == "Second consolidated plan")
        #expect(terminal.activePlan?.createdAt == secondDate)
        #expect(terminal.activePlan?.isApproved == false)
    }

    @Test
    func successfulTodoWritesSynchronizeApprovedPlanAndDetectCompletion() throws {
        let terminal = try makeTerminal()
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "Implement status tracking",
            consolidatedText: "Two steps",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "Implement command"),
                TerminalSessionPlanPoint(id: "plan-2", text: "Run tests"),
            ]
        )
        let result = DirectAgentToolResult(
            output: "updated",
            summary: "updated"
        )

        #expect(!terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [
                ("plan-1", "Implement command", "in_progress")
            ]),
            result: result
        ))
        #expect(terminal.activePlan?.points.map(\.status) == [.inProgress, .pending])

        #expect(terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [
                ("plan-1", "Implement command", "completed"),
                ("plan-2", "Run tests", "completed"),
            ]),
            result: result
        ))
        #expect(terminal.activePlan?.isCompleted == true)
        #expect(TerminalChat.planStatusTable(for: try #require(terminal.activePlan))
            .contains("**Overall status:** `completed`"))
    }

    @Test
    func failedOrUnrelatedTodoWritesDoNotChangePlanStatus() throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            originalGoal: "Keep status stable",
            consolidatedText: "One step",
            isApproved: true,
            points: [TerminalSessionPlanPoint(id: "plan-1", text: "Step")]
        )
        terminal.activePlan = plan

        #expect(!terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [("plan-1", "Step", "completed")]),
            result: DirectAgentToolResult(
                output: "Tool error: failed",
                summary: "failed",
                status: .failed
            )
        ))
        #expect(!terminal.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [("other", "Unrelated", "completed")]),
            result: DirectAgentToolResult(output: "updated", summary: "updated")
        ))
        #expect(terminal.activePlan == plan)
    }

    @Test
    func approvedPlanAddsProgressInstructionsToSystemPrompt() throws {
        let terminal = try makeTerminal()
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "Track plan",
            consolidatedText: "One step",
            isApproved: true,
            points: [TerminalSessionPlanPoint(id: "plan-1", text: "Implement")]
        )

        let prompt = try #require(terminal.systemPromptWithActivePlanProgress("Base prompt"))

        #expect(prompt.contains("Active approved plan progress:"))
        #expect(prompt.contains("plan-1 [pending]: Implement"))
        #expect(prompt.contains("The task graph is the authoritative control plane"))
        #expect(prompt.contains("common task workflow\npolicy in the session context"))
        #expect(!prompt.contains("tasks.list with runnableOnly=true"))
        #expect(!prompt.contains("Run independent read-only or implementation tasks in parallel"))
        #expect(!prompt.contains("todo.write"))
    }

    @Test
    func emptyOrNonPlanningOutputDoesNotReplaceActivePlan() throws {
        let terminal = try makeTerminal()
        let existing = TerminalSessionPlan(
            originalGoal: "existing",
            consolidatedText: "Keep this plan",
            createdAt: Date(timeIntervalSince1970: 10),
            isApproved: true
        )
        terminal.activePlan = existing

        #expect(!terminal.recordPlanIfNeeded(
            responseText: " \n ",
            purpose: .plan(originalGoal: "failed goal")
        ))
        #expect(!terminal.recordPlanIfNeeded(
            responseText: "ordinary response",
            purpose: .normal
        ))
        #expect(terminal.activePlan == existing)
    }

    @Test
    func approveRequiresACompletedPlanAndClearRemovesIt() async throws {
        let terminal = try makeTerminal()

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan approve")))
        #expect(terminal.activePlan == nil)

        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan"
        )
        let approvalAction = await terminal.handlePlanCommand("/plan approve")
        #expect(terminal.activePlan?.isApproved == true)
        guard case let .runHiddenPrompt(prompt, purpose) = approvalAction else {
            Issue.record("/plan approve should start implementation immediately")
            return
        }
        #expect(purpose == .normal)
        #expect(prompt.contains("Goal: goal"))
        #expect(prompt.contains("Approved plan:\nplan"))

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan clear")))
        #expect(terminal.activePlan == nil)
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan clear")))
    }

    @Test
    func undoKeepsPlanWhileNewSessionClearsIt() async throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan",
            isApproved: true
        )
        terminal.activePlan = plan
        var discussion = PlanningCommandRuntimeState(goal: "runtime-only discussion")
        discussion.recordPlannerOutput(
            "Planner questions\n1. Continue?",
            agentID: "planner-reset-test",
            revision: 1
        )
        terminal.planBrainstorming = discussion

        await terminal.handleUndoFileChangesCommand()
        #expect(terminal.activePlan == plan)
        #expect(terminal.planBrainstorming == discussion)

        await terminal.startNewSession()
        #expect(terminal.activePlan == nil)
        #expect(terminal.planBrainstorming == nil)
    }

    @Test
    func planDelegationPromptMakesOnePlannerTheSolePlanAuthor() {
        let planner = AgentProfile(
            id: AgentProfileStore.plannerAgentID.uuidString,
            name: AgentProfileStore.plannerAgentName,
            tools: []
        )

        let prompt = PlanningCommandKernel.planStartPrompt(
            goal: "add a Planner command",
            planner: planner
        )

        #expect(prompt.contains("Planning goal requested by the user: add a Planner command"))
        #expect(prompt.contains("agent.create"))
        #expect(prompt.contains("Create exactly one sub-agent"))
        #expect(prompt.contains("name \"plan-author\""))
        #expect(prompt.contains("role \"Planner\""))
        #expect(prompt.contains("profile \"\(planner.id)\""))
        #expect(prompt.contains("The Planner must not edit files or run mutating commands"))
        #expect(!prompt.contains("toolNames"))
        #expect(prompt.contains("agent.wait"))
        #expect(prompt.contains("same Planner to correct it with agent.message"))
        #expect(prompt.contains("call todo.write once with mode \"upsert\""))
        #expect(prompt.contains("stable IDs \"plan-<token>-1\""))
        #expect(prompt.contains("/plan <goal> -> /plan approve"))
        #expect(prompt.contains("automatically starts implementation"))
        #expect(prompt.contains("must not tell the user to send another implementation prompt"))
        #expect(prompt.contains("Planner agent is the sole author of the final plan"))
        #expect(prompt.contains("exactly the Planner's latest output, verbatim"))
        #expect(prompt.contains("do not author, draft, consolidate, rewrite, or improve"))
        #expect(prompt.contains("Do not edit any files yourself in this planning turn"))
        #expect(!prompt.contains("infer the activity to plan"))
        #expect(!prompt.contains("spawn multiple Planners"))
        #expect(!prompt.contains("Read and consolidate their plans"))
        #expect(!prompt.contains("local.writeFile"))
        #expect(!prompt.contains("local.exec"))
        #expect(!prompt.contains("git.add"))
        #expect(!prompt.contains("memory.write"))
    }

    @Test
    func planDelegationPromptRequiresSelfContainedFunctionalItems() {
        let planner = AgentProfile(
            id: AgentProfileStore.plannerAgentID.uuidString,
            name: AgentProfileStore.plannerAgentName,
            tools: []
        )

        let prompt = PlanningCommandKernel.planStartPrompt(
            goal: "add a Planner command",
            planner: planner
        )

        #expect(prompt.contains("concise, self-contained functional analysis"))
        #expect(prompt.contains("only that plan and the workspace"))
        #expect(prompt.contains("self-contained as a specification"))
        #expect(prompt.contains("after its declared dependencies"))
        #expect(prompt.contains("concrete observable behavior and relevant flow"))
        #expect(prompt.contains("verified components/files/symbols"))
        #expect(prompt.contains("applicable constraints and edge cases"))
        #expect(prompt.contains("concrete validation"))
        #expect(prompt.contains("Prohibit generic formulations, placeholders, repetition, alternatives"))
        #expect(prompt.contains("decisions left to the implementer"))
        #expect(prompt.contains("Do not include context summaries, generic background"))
        #expect(prompt.contains("non-pertinent sections, or detail that does not"))
        #expect(prompt.contains("Use the fewest points and words that preserve implementation certainty"))
        #expect(prompt.contains("Resolve needed decisions from the workspace and conversation"))
        #expect(prompt.contains("ask one focused question rather than guessing"))
        #expect(prompt.contains("only when pertinent to the requested work"))
        #expect(!prompt.contains("plus likely files/areas to touch"))
    }

    @Test
    func plannerAuthoredResponseIgnoresTheCurrentAgentsDraft() throws {
        let parentResponse = DirectAgentResponse(
            text: "Default rewrote the plan",
            stopReason: "end_turn",
            modelID: "default-model"
        )
        let response = try #require(TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: parentResponse,
            snapshots: [
                subAgentSnapshot(
                    name: "supporting-agent",
                    role: "Planner",
                    modelID: "other-model",
                    latestOutput: "Supporting notes",
                    updatedAt: Date(timeIntervalSince1970: 200)
                ),
                subAgentSnapshot(
                    name: TerminalChat.planAuthorAgentName,
                    role: "Planner",
                    modelID: "planner-model",
                    latestOutput: "Planner-authored final plan",
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        ))

        #expect(response.text == "Planner-authored final plan")
        #expect(response.stopReason == parentResponse.stopReason)
        #expect(response.modelID == "planner-model")
        #expect(response.text != parentResponse.text)
    }

    @Test
    func plannerAuthoredResponseRejectsAnIncompletePlanner() {
        let parentResponse = DirectAgentResponse(
            text: "Default fallback plan",
            stopReason: "end_turn",
            modelID: "default-model"
        )
        let response = TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: parentResponse,
            snapshots: [
                subAgentSnapshot(
                    name: TerminalChat.planAuthorAgentName,
                    role: "Planner",
                    status: .running,
                    pending: true,
                    latestOutput: "Draft"
                ),
                subAgentSnapshot(
                    name: "developer-agent",
                    role: "Developer",
                    latestOutput: "Default fallback plan"
                ),
            ]
        )

        #expect(response == nil)
    }

    @Test
    func plannerAuthoredResponseRejectsAPlannerRoleUsingTheDeveloperProfile() {
        let response = TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: DirectAgentResponse(
                text: "Default fallback plan",
                stopReason: "end_turn",
                modelID: "default-model"
            ),
            snapshots: [
                subAgentSnapshot(
                    name: TerminalChat.planAuthorAgentName,
                    role: "Planner",
                    profileName: "Developer",
                    latestOutput: "Impersonated plan"
                )
            ]
        )

        #expect(response == nil)
    }

    @Test
    func plannerAuthoredResponseAcceptsAClosedPlanner() throws {
        let response = try #require(TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: DirectAgentResponse(
                text: "Default fallback plan",
                stopReason: "end_turn",
                modelID: "default-model"
            ),
            snapshots: [
                subAgentSnapshot(
                    name: TerminalChat.planAuthorAgentName,
                    role: "Planner",
                    status: .closed,
                    modelID: "planner-model",
                    latestOutput: "Planner plan after closure"
                )
            ]
        ))
        #expect(response.text == "Planner plan after closure")
        #expect(response.modelID == "planner-model")
    }

    @Test
    func plannerAuthoredResponseUsesFreshLatestOutputInsteadOfAccumulatedHistory() throws {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-plan-author",
            name: TerminalChat.planAuthorAgentName,
            role: "Planner",
            profileName: AgentProfileStore.plannerAgentName,
            status: .idle,
            pending: false,
            modelID: "planner-model",
            latestOutput: "Final fragment only",
            accumulatedOutput: "First part of the plan\n\nFinal fragment only",
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let response = try #require(TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: DirectAgentResponse(
                text: "Default fallback plan",
                stopReason: "end_turn",
                modelID: "default-model"
            ),
            snapshots: [snapshot]
        ))
        #expect(response.text == "Final fragment only")
    }

    @Test
    func plannerAuthoredResponseRejectsAPreexistingPlanAuthor() {
        let staleAuthor = subAgentSnapshot(
            name: TerminalChat.planAuthorAgentName,
            role: "Planner",
            latestOutput: "Plan for the previous goal"
        )
        let response = TerminalChat.plannerAuthoredPlanResponse(
            parentResponse: DirectAgentResponse(
                text: "Default fallback plan",
                stopReason: "end_turn",
                modelID: "default-model"
            ),
            snapshots: [staleAuthor],
            excludingAgentIDs: [staleAuthor.id]
        )

        #expect(response == nil)
    }

    @Test
    func plannerOutputReplacesCoordinatorTextInOperationalHistory() {
        let toolCall = AgentRuntimeToolCall(
            id: "create-planner",
            name: "agent.create",
            argumentsJSON: "{}"
        )
        let history = [
            AgentRuntimeMessage(role: .user, content: "Earlier question"),
            AgentRuntimeMessage(role: .assistant, content: "Earlier answer"),
            AgentRuntimeMessage(role: .user, content: "Hidden planning prompt"),
            AgentRuntimeMessage(role: .assistant, content: "I will coordinate the plan."),
            AgentRuntimeMessage(role: .assistant, content: "", toolCalls: [toolCall]),
            AgentRuntimeMessage(
                role: .tool,
                content: "Planner completed",
                toolCallID: "create-planner",
                toolName: "agent.create"
            ),
            AgentRuntimeMessage(
                role: .assistant,
                content: "Default-authored replacement plan",
                providerResponseID: "default-response"
            ),
        ]

        let corrected = PlanningCommandKernel.historyByReplacingCoordinatorOutput(
            history,
            with: "Planner-authored final plan"
        )

        #expect(corrected.prefix(2) == history.prefix(2))
        #expect(!corrected.contains { $0.content.contains("Hidden planning prompt") })
        #expect(corrected.contains { $0.toolCalls == [toolCall] })
        #expect(corrected.contains { $0.role == .tool })
        #expect(!corrected.contains { $0.content.contains("coordinate") })
        #expect(!corrected.contains { $0.content.contains("Default-authored") })
        #expect(corrected.last?.role == .assistant)
        #expect(corrected.last?.content == "Planner-authored final plan")
        #expect(corrected.last?.providerResponseID == nil)
    }

    @Test
    func taskDefinitionsUseOnlyRealDependenciesInsteadOfListOrder() {
        let definitions = TerminalChat.taskDefinitions(for: [
            TerminalSessionPlanPoint(id: "plan-dag-1", text: "Update module A"),
            TerminalSessionPlanPoint(id: "plan-dag-2", text: "Update module B"),
            TerminalSessionPlanPoint(
                id: "plan-dag-3",
                text: "Run integrated validation",
                dependsOn: ["plan-dag-1", "plan-dag-2"],
                hasExplicitDependencies: true
            ),
        ])

        #expect(definitions.map(\.dependsOn) == [
            [],
            [],
            ["plan-dag-1", "plan-dag-2"],
        ])
    }

    @Test
    func validPlanIsRecordedWithoutGraphAndApprovalCreatesActiveGraph() async throws {
        let terminal = try makeTerminal()
        let points = [
            TerminalSessionPlanPoint(
                id: "plan-graph-1",
                text: "Implement model",
                dependsOn: [],
                hasExplicitDependencies: true
            ),
            TerminalSessionPlanPoint(
                id: "plan-graph-2",
                text: "Run validation",
                dependsOn: ["plan-graph-1"],
                hasExplicitDependencies: true
            ),
        ]

        #expect(try await terminal.recordStructuredPlanIfNeeded(
            responseText: "1. Implement model\n2. Run validation",
            purpose: .plan(originalGoal: "Ship graph"),
            points: points
        ))
        // The task graph is NOT created during plan definition, only at approval.
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-graph"
        ) == nil)
        #expect(terminal.activePlan?.id == "plan-graph")

        let approval = await terminal.handlePlanCommand("/plan approve")
        guard case .runHiddenPrompt = approval else {
            Issue.record("Approval should create and activate the task graph")
            return
        }
        let active = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-graph"
        ))
        #expect(active.state == .active)
        #expect(active.source == .plan(planID: "plan-graph"))
        #expect(active.tasks.map(\.dependsOn) == [[], ["plan-graph-1"]])

        let receipt = try #require(try await terminal.sessionRunner.taskOrchestrator.claimTasks(
            sessionID: terminal.sessionID,
            claims: [TaskClaim(taskID: "plan-graph-1", agentID: "worker")]
        ).first)
        _ = try await terminal.sessionRunner.taskOrchestrator.completeAttempt(
            sessionID: terminal.sessionID,
            taskID: "plan-graph-1",
            attemptID: receipt.attemptID,
            output: "done",
            requiresValidation: false
        )
        _ = await terminal.handlePlanCommand("/plan status")
        #expect(terminal.activePlan?.points.map(\.status) == [.completed, .pending])
        #expect(try await terminal.sessionRunner.taskOrchestrator.task(
            sessionID: terminal.sessionID,
            taskID: "plan-graph-2"
        ).isRunnable)
    }

    @Test
    func approvalAcceptsPlanTaskTitlesLongerThanTheFormerLimit() async throws {
        let terminal = try makeTerminal()
        let longTitle = String(repeating: "x", count: 1_024)
        let plan = TerminalSessionPlan(
            id: "plan-long-title",
            originalGoal: "Keep the full plan item",
            consolidatedText: "Implement the long plan item.",
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-long-title-1",
                    text: longTitle
                )
            ]
        )
        terminal.activePlan = plan

        let approval = await terminal.handlePlanCommand("/plan approve")

        guard case .runHiddenPrompt = approval else {
            Issue.record("Approval should accept a plan task title longer than 512 characters")
            return
        }
        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: plan.id
        ))
        #expect(terminal.activePlan?.isApproved == true)
        #expect(graph.state == .active)
        #expect(graph.tasks.map(\.title) == [longTitle])
    }

    @Test
    func planReplacementSucceedsAndInvalidDependenciesSurfaceAtApproval() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.recordStructuredPlanIfNeeded(
            responseText: "1. Existing",
            purpose: .plan(originalGoal: "Existing"),
            points: [TerminalSessionPlanPoint(id: "plan-old-1", text: "Existing")]
        )

        // Plan definition no longer validates task dependencies; the graph is
        // created exclusively at approval time.
        _ = try await terminal.recordStructuredPlanIfNeeded(
            responseText: "1. Invalid",
            purpose: .plan(originalGoal: "Invalid"),
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-new-1",
                    text: "Invalid",
                    dependsOn: ["missing"],
                    hasExplicitDependencies: true
                )
            ]
        )

        // The replacement succeeded at definition time.
        #expect(terminal.activePlan?.originalGoal == "Invalid")
        #expect(terminal.activePlan?.id == "plan-new")
        // No graph exists yet (not created during definition).
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-new"
        ) == nil)

        // Approval fails because the graph cannot be created with a missing dependency.
        _ = await terminal.handlePlanCommand("/plan approve")
        #expect(terminal.activePlan?.isApproved == false)
    }

    @Test
    func changingPlanBeforeApprovalProducesGraphWithUpdatedTasks() async throws {
        let terminal = try makeTerminal()

        // First plan definition: two tasks.
        _ = try await terminal.recordStructuredPlanIfNeeded(
            responseText: "1. First\n2. Second",
            purpose: .plan(originalGoal: "Goal"),
            points: [
                TerminalSessionPlanPoint(id: "plan-changed-1", text: "First"),
                TerminalSessionPlanPoint(id: "plan-changed-2", text: "Second"),
            ]
        )
        #expect(terminal.activePlan?.points.count == 2)

        // The user revises the plan before approving: now three tasks with
        // different content. Because the graph is not created during definition,
        // this replacement does not touch any stale graph.
        _ = try await terminal.recordStructuredPlanIfNeeded(
            responseText: "1. Revised A\n2. Revised B\n3. Revised C",
            purpose: .plan(originalGoal: "Goal"),
            points: [
                TerminalSessionPlanPoint(id: "plan-changed-1", text: "Revised A"),
                TerminalSessionPlanPoint(id: "plan-changed-2", text: "Revised B"),
                TerminalSessionPlanPoint(id: "plan-changed-3", text: "Revised C"),
            ]
        )
        #expect(terminal.activePlan?.points.count == 3)
        #expect(terminal.activePlan?.points.map(\.text) == ["Revised A", "Revised B", "Revised C"])

        // Approving must create a graph that reflects the final (revised) tasks,
        // not the original ones.
        let approval = await terminal.handlePlanCommand("/plan approve")
        guard case .runHiddenPrompt = approval else {
            Issue.record("Approval should start implementation")
            return
        }
        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-changed"
        ))
        #expect(graph.state == .active)
        #expect(graph.tasks.count == 3)
        #expect(graph.tasks.map(\.title) == ["Revised A", "Revised B", "Revised C"])
        #expect(graph.tasks.map(\.id) == ["plan-changed-1", "plan-changed-2", "plan-changed-3"])
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-plan-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.selectedToolKeys.insert("sub-agents")
        return terminal
    }

    private func isContinueChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action {
            return true
        }
        return false
    }

    private func todoWriteCall(
        items: [(id: String, content: String, status: String)]
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "todo-write",
            name: "todo.write",
            argumentsObject: [
                "mode": "upsert",
                "todos": items.map { item in
                    [
                        "id": item.id,
                        "content": item.content,
                        "status": item.status,
                    ]
                },
            ],
            argumentsJSON: "{}"
        )
    }

    private func subAgentSnapshot(
        name: String,
        role: String,
        status: DirectSubAgentRuntime.Status = .idle,
        pending: Bool = false,
        modelID: String? = nil,
        profileName: String? = AgentProfileStore.plannerAgentName,
        latestOutput: String?,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-\(name)",
            name: name,
            role: role,
            profileName: profileName,
            status: status,
            pending: pending,
            modelID: modelID,
            latestOutput: latestOutput,
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt
        )
    }
}

@TerminalChatActor
@Suite(.serialized)
struct PlanApprovalResponseLanguageTests {
    @Test
    func approvalUsesConfiguredItalianResponseLanguageForItsInternalPrompt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanApprovalLanguageTests-\(UUID().uuidString)", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("support", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        AppStorageDirectory.configureSupportDirectoryURL(supportDirectory)
        AgentSettingsManifestStore.resetDefaultCacheForTesting()
        defer {
            AppStorageDirectory.configureSupportDirectoryURL(nil)
            AgentSettingsManifestStore.resetDefaultCacheForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], responseLanguage: "it")
        )

        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: workingDirectory
            ),
            stdinIsTerminal: false
        )
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "Correggere la lingua del piano",
            consolidatedText: "Implementa e valida la correzione."
        )

        #expect(!terminal.didLockResponseLanguage)
        guard case .runHiddenPrompt = await terminal.handlePlanCommand("/plan approve") else {
            Issue.record("Approval should start the internal implementation prompt")
            return
        }

        #expect(terminal.didLockResponseLanguage)
        #expect(terminal.activeResponseLanguageName == "Italian")
        let systemPrompt = try #require(
            terminal.currentSessionConfiguration(allowedToolNames: []).systemPrompt
        )
        #expect(systemPrompt.contains("locked to Italian"))
        #expect(systemPrompt.contains("Use Italian for all natural-language replies"))
    }
}
