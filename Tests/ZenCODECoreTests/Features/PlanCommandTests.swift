//
//  PlanCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite
struct PlanCommandTests {
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
    func savedPlanPreparationPreservesNormalizationAndGraphPointPrecedence() throws {
        let source = try JSONDecoder().decode(TerminalSessionPlan.self, from: Data("""
        {
          "id": "plan-reset",
          "originalGoal": "  Keep the goal  ",
          "consolidatedText": "  Keep the body  ",
          "createdAt": 42,
          "isApproved": true,
          "points": [
            {"id": "plan-reset-1", "text": "  First  ", "status": "failed",
             "dependsOn": ["  predecessor  ", "  "], "hasExplicitDependencies": false},
            {"id": "plan-reset-1", "text": "Duplicate", "status": "completed",
             "dependsOn": [], "hasExplicitDependencies": true}
          ]
        }
        """.utf8))
        let prepared = PlanningCommandKernel.planPreparedForSaving(source)
        #expect(prepared.id == source.id)
        #expect(prepared.originalGoal == "Keep the goal")
        #expect(prepared.consolidatedText == "Keep the body")
        #expect(prepared.createdAt == source.createdAt)
        #expect(!prepared.isApproved)
        #expect(prepared.points.map(\.status) == [.pending, .pending])
        #expect(prepared.points[0].text == "First")
        #expect(prepared.points[0].dependsOn == ["predecessor"])
        #expect(!prepared.points[0].hasExplicitDependencies)

        func savedPlan(tasks: [TaskRecord]) -> SavedTaskPlan {
            SavedTaskPlan(
                librarySessionID: "saved-plans-test",
                graph: TaskGraphSnapshot(
                    id: source.id,
                    source: .plan(planID: source.id),
                    state: .draft,
                    tasks: tasks,
                    createdAt: source.createdAt,
                    updatedAt: source.createdAt
                ),
                snapshot: TaskGraphSavedPlan(plan: source)
            )
        }
        #expect(PlanningCommandKernel.planPreparedForReuse(savedPlan(tasks: [])) == prepared)
        let reused = PlanningCommandKernel.planPreparedForReuse(savedPlan(tasks: [
            TaskRecord(id: "plan-reset-3", title: "Third", order: 2),
            TaskRecord(
                id: "plan-reset-2", title: "Second", order: 1,
                dependsOn: ["plan-reset-1"]
            ),
            TaskRecord(
                id: "plan-reset-1", title: "Graph first", order: 1,
                dependsOn: ["predecessor"]
            ),
        ]))
        #expect(reused.id == prepared.id)
        #expect(reused.originalGoal == prepared.originalGoal)
        #expect(reused.consolidatedText == prepared.consolidatedText)
        #expect(reused.createdAt == prepared.createdAt)
        #expect(!reused.isApproved)
        #expect(reused.points.map(\.id) == ["plan-reset-1", "plan-reset-2", "plan-reset-3"])
        #expect(reused.points.map(\.text) == ["Graph first", "Second", "Third"])
        #expect(reused.points.map(\.status) == [.pending, .pending, .pending])
        #expect(reused.points.map(\.hasExplicitDependencies) == [false, true, false])
        #expect(reused.points.map(\.dependsOn) == [["predecessor"], ["plan-reset-1"], []])
    }

    @Test
    func planStatusPreservesGraphAndLocalStatusPrecedence() {
        let now = Date(timeIntervalSince1970: 10)
        let priority: [TaskStatus] = [
            .failed, .blocked, .inProgress, .awaitingValidation, .cancelled, .pending,
        ]
        for index in priority.indices {
            let tasks = priority[index...].reversed().enumerated().map { offset, status in
                TaskRecord(id: "point-\(offset)", title: "Point", order: offset, status: status)
            }
            var plan = TerminalSessionPlan(
                originalGoal: "Track precedence",
                consolidatedText: "Plan body",
                isApproved: true,
                points: tasks.map { task in
                    TerminalSessionPlanPoint(
                        id: task.id, text: task.title,
                        status: PlanningCommandKernel.planPointStatus(for: task.status)
                    )
                }
            )
            let graphStates: [TaskGraphState] = [.active, .draft, .completed, .cancelled, .archived]
            for state in graphStates {
                let graph = TaskGraphSnapshot(
                    id: plan.id, source: .plan(planID: plan.id), state: state,
                    tasks: tasks, createdAt: now, updatedAt: now
                )
                let expected = state == .active
                    ? (priority[index] == .pending ? "active" : priority[index].rawValue)
                    : (state == .draft ? "awaiting_approval" : state.rawValue)
                #expect(PlanningCommandKernel.planStatusTable(for: plan, graph: graph)
                    .contains("**Overall status:** `\(expected)`"))
            }
            for approved in [false, true] {
                plan.isApproved = approved
                let expected = index < 4 ? priority[index].rawValue
                    : (approved ? "pending" : "awaiting_approval")
                #expect(PlanningCommandKernel.planStatusTable(for: plan, graph: nil)
                    .contains("**Overall status:** `\(expected)`"))
            }
        }
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
            #expect(prompt.contains("runtime profile policy owns the brainstorming and plan-authoring protocol"))
            #expect(prompt.contains("translate every explicit dependency to those IDs"))
            #expect(prompt.contains("empty arrays for independent items"))
            #expect(!prompt.contains("\"Dependencies\" entry"))
            #expect(!prompt.contains("DAG with the minimum safe edges"))
            #expect(purpose == .plan(originalGoal: "fix the planner command"))
        case .runPrompt(_):
            Issue.record("/plan <goal> should keep the generated delegation prompt hidden")
        default:
            Issue.record("/plan <goal> should start the planning delegation prompt")
        }
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
                profileID: AgentProfileRole.planner.rawValue,
                profileRole: .planner,
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
    func initialPlanningTurnRequiresPlannerQuestionsBeforeAcceptingFinalPlan() {
        func snapshot(revision: UInt64, output: String) -> DirectSubAgentRuntime.AgentSnapshot {
            DirectSubAgentRuntime.AgentSnapshot(
                id: "planner-initial",
                rootSessionID: "planning-session",
                name: PlanningCommandKernel.planAuthorAgentName,
                role: AgentProfileStore.plannerAgentName,
                profileID: AgentProfileRole.planner.rawValue,
                profileRole: .planner,
                status: .idle,
                pending: false,
                latestOutput: output,
                latestOutputRevision: revision,
                latestError: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)
            )
        }

        let initialBaseline = PlannerTurnBaseline(
            state: PlanningCommandRuntimeState(goal: "harden plan routing"),
            snapshots: [],
            rootSessionID: "planning-session"
        )
        let parentResponse = DirectAgentResponse(
            text: "Coordinator response must not be used.",
            stopReason: "stop",
            modelID: "coordinator"
        )
        let finalPlan = snapshot(
            revision: 1,
            output: "Specifiche concordate\n\nImplementation plan\n1. Implement"
        )
        #expect(PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: [finalPlan],
            baseline: initialBaseline,
            rootSessionID: "planning-session"
        ) == nil)

        let question = snapshot(
            revision: 2,
            output: "Planner questions\n1. Which compatibility behavior is required?"
        )
        #expect(PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: [question],
            baseline: initialBaseline,
            rootSessionID: "planning-session"
        )?.snapshot.id == "planner-initial")

        let invalidInitialOutputs = [
            "Planner questions",
            "Planner questions\nWhich compatibility behavior is required?",
            "Planner questions: choose a behavior\n1. Which one?",
            "Planner questions\n1. Which one?\n\nPlanner questions:\n2. Another?",
            "Planner questions\n1. Which one?\n\nPlanner questions: duplicate\n2. Another?",
            "Planner questions\n1. Which one?\n\nSpecifiche concordate\nImplementation plan\n1. Implement",
            "Planner questions\n1. Which one?\n\n## Implementation plan:\n1. Implement",
        ]
        for (offset, output) in invalidInitialOutputs.enumerated() {
            #expect(!PlanningCommandKernel.isPlannerQuestionResponse(output))
            #expect(PlanningCommandKernel.plannerResponse(
                parentResponse: parentResponse,
                snapshots: [snapshot(revision: UInt64(offset + 10), output: output)],
                baseline: initialBaseline,
                rootSessionID: "planning-session"
            ) == nil)
        }
        #expect(PlanningCommandKernel.isPlannerQuestionResponse(
            "\n# Planner questions:\n1) Which compatibility behavior is required?"
        ))
        // The raw validation stays strict about a preamble; only the
        // Planner-authored block extracted by `plannerResponse` is accepted.
        let narratedQuestions = "Intro\nPlanner questions\n1. Which one?"
        #expect(!PlanningCommandKernel.isPlannerQuestionResponse(narratedQuestions))
        #expect(PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: [snapshot(revision: 30, output: narratedQuestions)],
            baseline: initialBaseline,
            rootSessionID: "planning-session"
        )?.response.text == "Planner questions\n1. Which one?")

        var followUpState = PlanningCommandRuntimeState(goal: "harden plan routing")
        followUpState.recordPlannerOutput(
            question.latestOutput!,
            agentID: question.id,
            revision: question.latestOutputRevision
        )
        let recordedReply = followUpState.recordReply("Keep existing clients compatible.")
        #expect(recordedReply)
        let followUpBaseline = PlannerTurnBaseline(
            state: followUpState,
            snapshots: [question],
            rootSessionID: "planning-session"
        )
        #expect(PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: [snapshot(
                revision: 3,
                output: "Specifiche concordate\n\nImplementation plan\n1. Implement"
            )],
            baseline: followUpBaseline,
            rootSessionID: "planning-session"
        )?.response.text.hasPrefix("Specifiche concordate") == true)
    }

    @Test
    func derivedPlanPointsPreserveNormalizationAndRejectEveryInvalidDependencyShape() throws {
        func text(firstDependencies: String, secondDependencies: String) -> String {
            """
            Specifiche concordate
            Keep the scope.

            Implementation plan
            1.   Inspect the workspace.\("  ")
               Keep existing constraints.
               Dependencies: \(firstDependencies)
            2. Validate the result.
               Dependencies: \(secondDependencies)
            """
        }
        let points = try #require(PlanningCommandKernel.planPoints(
            derivedFromFinalText: text(firstDependencies: "none", secondDependencies: "[1]"),
            identifierToken: "ab-1"
        ))
        #expect(points.map(\.id) == ["plan-ab1-1", "plan-ab1-2"])
        #expect(points.map(\.text) == [
            "Inspect the workspace.\nKeep existing constraints.", "Validate the result.",
        ])
        #expect(points.map(\.status) == [.pending, .pending])
        #expect(points.map(\.dependsOn) == [[], ["plan-ab1-1"]])
        #expect(points.allSatisfy { $0.hasExplicitDependencies })
        for (first, second) in [
            ("none", "0"), ("none", "-1"), ("none", "3"), ("none", "1, 1"),
            ("1", "none"), ("none", "2"), ("2", "1"), ("none", "invalid"),
        ] {
            #expect(PlanningCommandKernel.planPoints(
                derivedFromFinalText: text(firstDependencies: first, secondDependencies: second),
                identifierToken: "ab-1"
            ) == nil)
        }
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

    private static let structuredThreePointPlannerFinalText = """
    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Add the shared model.
       Dependencies: none
    2. Wire the TUI command.
       Dependencies: 1
    3. Validate every frontend.
       Dependencies: 1, 2
    """

    @Test
    func promotedStructuredPlannerResponseKeepsEveryPointAndDependency() throws {
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Ship the shared routing"),
            AgentRuntimeMessage(
                role: .assistant,
                content: Self.structuredThreePointPlannerFinalText
            ),
        ]

        let plan = try #require(
            PlanningCommandKernel.planFromLatestAssistantMessage(in: messages)
        )
        #expect(plan.originalGoal == "Ship the shared routing")
        #expect(plan.consolidatedText == Self.structuredThreePointPlannerFinalText)
        #expect(plan.isApproved == false)
        #expect(plan.id == PlanningCommandKernel.planID(from: plan.points))
        #expect(plan.id.hasPrefix("plan-"))
        #expect(plan.points.map(\.id) == (1...3).map { "\(plan.id)-\($0)" })
        #expect(plan.points.map(\.text) == [
            "Add the shared model.",
            "Wire the TUI command.",
            "Validate every frontend.",
        ])
        #expect(plan.points.map(\.dependsOn) == [
            [],
            ["\(plan.id)-1"],
            ["\(plan.id)-1", "\(plan.id)-2"],
        ])
        #expect(plan.points.allSatisfy { $0.hasExplicitDependencies })
        #expect(plan.points.allSatisfy { $0.status == .pending })
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: plan.consolidatedText,
            points: plan.points
        ))
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
    func approveRequiresACompletedPlanAndClearRemovesIt() async throws {
        let terminal = try makeTerminal()

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan approve")))
        #expect(terminal.activePlan == nil)

        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan"
        )
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan approve")))
        let approvalAction = await terminal.submittedLineAction("Ship the planned work")
        #expect(terminal.activePlan?.isApproved == true)
        #expect(terminal.activePlan?.originalGoal == "Ship the planned work")
        guard case let .runHiddenPrompt(prompt, purpose) = approvalAction else {
            Issue.record("/plan approve should start implementation immediately")
            return
        }
        #expect(purpose == .normal)
        #expect(prompt.contains("Goal: Ship the planned work"))
        #expect(prompt.contains("Approved plan:\nplan"))

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan clear")))
        #expect(terminal.activePlan == nil)
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan clear")))
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

        #expect(isContinueChat(await terminal.handlePlanCommand("/plan approve")))
        let approval = await terminal.submittedLineAction("Ship graph execution")
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
        profileRole: AgentProfileRole? = .planner,
        latestOutput: String?,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-\(name)",
            name: name,
            role: role,
            profileName: profileName,
            profileRole: profileRole,
            status: status,
            pending: pending,
            modelID: modelID,
            latestOutput: latestOutput,
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt
        )
    }

    private static let structuredPlannerFinalText = """
    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Implement shared routing.
       Dependencies: none
    2. Validate every frontend.
       Dependencies: 1
    """

    @Test
    func collectorDerivesFinalPlanPointsWhenCoordinatorSkippedTodoWrite() async throws {
        let collector = PlanningPointCollector()

        #expect(await collector.validFinalPlanPoints() == nil)
        let resolved = try #require(
            await collector.finalPlanPoints(
                forFinalText: Self.structuredPlannerFinalText
            )
        )
        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy({ $0.hasExplicitDependencies }))
        #expect(resolved.allSatisfy({ $0.status == .pending }))
        #expect(resolved.last?.dependsOn == [resolved[0].id])
        #expect(PlanningCommandKernel.structuredPlanOutputIsCoherent(
            text: Self.structuredPlannerFinalText,
            points: resolved
        ))
        // The derived registration is stable and visible to later readers.
        #expect(await collector.snapshot() == resolved)
        #expect(await collector.finalPlanPoints(
            forFinalText: Self.structuredPlannerFinalText
        ) == resolved)
    }

    private static let twoPlanPlannerFinalText = """
    Piano 1/2: Modello condiviso

    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Add the shared model.
       Dependencies: none
    2. Wire the TUI command.
       Dependencies: 1

    Piano 2/2: Validazione

    Specifiche concordate
    - Validate every frontend.

    Implementation plan
    1. Validate the ACP bridge.
       Dependencies: none
    """

    private static let twoPlanFirstSectionText = """
    Piano 1/2: Modello condiviso

    Specifiche concordate
    - Keep compatibility.

    Implementation plan
    1. Add the shared model.
       Dependencies: none
    2. Wire the TUI command.
       Dependencies: 1
    """

    private static let twoPlanSecondSectionText = """
    Piano 2/2: Validazione

    Specifiche concordate
    - Validate every frontend.

    Implementation plan
    1. Validate the ACP bridge.
       Dependencies: none
    """

    private static func registeredPoint(
        _ id: String,
        _ text: String,
        dependsOn: [String] = []
    ) -> TerminalSessionPlanPoint {
        TerminalSessionPlanPoint(
            id: id,
            text: text,
            dependsOn: dependsOn,
            hasExplicitDependencies: true
        )
    }

    private static let twoPlanRegisteredPoints = [
        registeredPoint("plan-alpha-1", "Add the shared model."),
        registeredPoint("plan-alpha-2", "Wire the TUI command.", dependsOn: ["plan-alpha-1"]),
        registeredPoint("plan-beta-1", "Validate the ACP bridge."),
    ]

    @Test
    func collectorResolvesPlanSectionsWithAndWithoutTodoWrite() async throws {
        let derivedCollector = PlanningPointCollector()
        let derived = try #require(await derivedCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ))
        #expect(derived.count == 2)
        #expect(derived.map(\.points.count) == [2, 1])
        #expect(await derivedCollector.snapshot() == derived.flatMap(\.points))
        // The cached derivation is reused for the same final text.
        #expect(await derivedCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ) == derived)
        #expect(await derivedCollector.finalPlanPoints(
            forFinalText: Self.twoPlanPlannerFinalText
        ) == derived.flatMap(\.points))

        let registeredCollector = PlanningPointCollector()
        await registeredCollector.recordTodoWrite(
            (points: Self.twoPlanRegisteredPoints, mode: .upsert)
        )
        let registered = try #require(await registeredCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ))
        #expect(registered.map(\.heading) == ["Piano 1/2: Modello condiviso", "Piano 2/2: Validazione"])
        #expect(registered.map { $0.points.map(\.id) } == [
            ["plan-alpha-1", "plan-alpha-2"],
            ["plan-beta-1"],
        ])
        #expect(await registeredCollector.finalPlanPoints(
            forFinalText: Self.twoPlanPlannerFinalText
        ) == Self.twoPlanRegisteredPoints)

        // A registration that does not split by plan is never replaced by a
        // derived fallback.
        let mismatchedCollector = PlanningPointCollector()
        await mismatchedCollector.recordTodoWrite(
            (points: Array(Self.twoPlanRegisteredPoints[0...1]), mode: .upsert)
        )
        #expect(await mismatchedCollector.finalPlanSections(
            forFinalText: Self.twoPlanPlannerFinalText
        ) == nil)
    }

    @Test
    func promotedMultiPlanResponseYieldsOnePlanPerSection() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let messages = [
            AgentRuntimeMessage(role: .user, content: "Ship the shared routing"),
            AgentRuntimeMessage(role: .assistant, content: Self.twoPlanPlannerFinalText),
        ]

        let plans = PlanningCommandKernel.plansFromLatestAssistantMessage(
            in: messages,
            createdAt: createdAt
        )
        #expect(plans.count == 2)
        #expect(plans.map(\.originalGoal) == [
            "Piano 1/2: Modello condiviso — Ship the shared routing",
            "Piano 2/2: Validazione — Ship the shared routing",
        ])
        #expect(plans.map(\.consolidatedText) == [
            Self.twoPlanFirstSectionText,
            Self.twoPlanSecondSectionText,
        ])
        #expect(plans.map { $0.points.map(\.text) } == [
            ["Add the shared model.", "Wire the TUI command."],
            ["Validate the ACP bridge."],
        ])
        #expect(plans.allSatisfy { $0.id == PlanningCommandKernel.planID(from: $0.points) })
        #expect(Set(plans.map(\.id)).count == 2)
        #expect(plans.allSatisfy { $0.createdAt == createdAt && !$0.isApproved })
        #expect(plans[1].points.first?.dependsOn == [])

        let first = try #require(PlanningCommandKernel.planFromLatestAssistantMessage(in: messages))
        #expect(first.originalGoal == plans[0].originalGoal)
        #expect(first.consolidatedText == plans[0].consolidatedText)
    }
}
