//
//  PlanCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

@ChatSessionActor
@Suite
struct PlanCommandTests {
    @Test
    func savedPlanDeletionTargetResolvesAllExactAndUniquePrefix() {
        let planIDs = ["plan-aaaa1111", "plan-aaaa2222", "plan-bbbb3333"]

        #expect(
            PlanningCommandKernel.savedPlanDeletionTarget("ALL", in: planIDs)
                == .ids(planIDs)
        )
        #expect(
            PlanningCommandKernel.savedPlanDeletionTarget("plan-bbbb3333", in: planIDs)
                == .ids(["plan-bbbb3333"])
        )
        #expect(
            PlanningCommandKernel.savedPlanDeletionTarget("plan-bbbb", in: planIDs)
                == .ids(["plan-bbbb3333"])
        )
        #expect(
            PlanningCommandKernel.savedPlanDeletionTarget("plan-aaaa", in: planIDs)
                == .ambiguous(matches: ["plan-aaaa1111", "plan-aaaa2222"])
        )
        #expect(
            PlanningCommandKernel.savedPlanDeletionTarget("plan-zzzz", in: planIDs)
                == .notFound
        )
        #expect(
            PlanningCommandKernel.savedPlanDeletionTarget("   ", in: planIDs)
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
            stdinIsTerminal: false,
            telegramTransportFactory: nil
        )
        terminal.selectedToolKeys.insert("sub-agents")

        let action = await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan"))

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
            stdinIsTerminal: false,
            telegramTransportFactory: nil
        )
        terminal.selectedToolKeys.insert("sub-agents")

        let action = await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan fix the planner command"))

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
}
