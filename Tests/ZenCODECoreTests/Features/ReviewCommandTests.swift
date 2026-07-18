//
//  ReviewCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/06/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct ReviewCommandTests {
    @Test
    func defaultReviewerProfileDoesNotEnableShell() throws {
        let reviewer = try #require(
            AgentProfileStore.defaultProfiles().first(where: TerminalChat.isReviewerProfile)
        )

        #expect(!reviewer.tools.contains("shell"))
        #expect(reviewer.tools == AgentProfileStore.reviewerToolNames)
    }

    @Test
    func reviewerToolAllowlistExcludesGitAndMemory() {
        let reviewer = AgentProfile(
            id: AgentProfileStore.reviewerAgentID.uuidString,
            name: AgentProfileStore.reviewerAgentName,
            tools: [
                "local.readFile",
                "local.inspectFile",
                "search.grep",
                "search.locate",
                "git.diff",
                "memory.read"
            ]
        )

        let tools = TerminalChat.reviewerSubAgentToolNames(for: reviewer)

        #expect(tools.contains("local.readFile"))
        #expect(tools.contains("local.inspectFile"))
        #expect(tools.contains("search.grep"))
        #expect(tools.contains("search.locate"))
        #expect(!tools.contains("git.diff"))
        #expect(!tools.contains("memory.read"))
    }

    @Test
    func reviewerToolAllowlistDoesNotExpandAnEmptyProfile() {
        let reviewer = AgentProfile(
            id: AgentProfileStore.reviewerAgentID.uuidString,
            name: AgentProfileStore.reviewerAgentName,
            tools: []
        )

        #expect(TerminalChat.reviewerSubAgentToolNames(for: reviewer).isEmpty)
    }

    @Test
    func reviewDelegationPromptUsesOnlySessionChangeSummaryForScope() {
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/Example.swift",
                additions: 2,
                deletions: 1,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: """
                diff --git a/Sources/Example.swift b/Sources/Example.swift
                --- a/Sources/Example.swift
                +++ b/Sources/Example.swift
                @@ -1,2 +1,3 @@
                -old
                +new
                +line
                """
            )
        ])
        let reviewer = AgentProfile(
            id: AgentProfileStore.reviewerAgentID.uuidString,
            name: AgentProfileStore.reviewerAgentName,
            tools: []
        )

        let prompt = TerminalChat.reviewDelegationPrompt(
            scope: "focus on errors",
            reviewer: reviewer,
            changeSummary: summary
        )

        #expect(prompt.contains("Session change surface:"))
        #expect(prompt.contains("- modified Sources/Example.swift  +2 -1"))
        #expect(prompt.contains("diff --git a/Sources/Example.swift b/Sources/Example.swift"))
        #expect(prompt.contains("Review focus requested by the user: focus on errors"))
        #expect(prompt.contains("Apply this focus only within the tracked file changes"))
        #expect(!prompt.contains("git status"))
        #expect(!prompt.contains("recent log"))
        #expect(!prompt.contains("project journal"))
        #expect(!prompt.contains("project memory"))
        #expect(!prompt.contains("memory tools"))
        #expect(!prompt.contains("Approved plan under verification"))
        #expect(!prompt.contains("done, partial, missing, or deviated"))
    }

    @Test
    func reviewPromptIncludesApprovedPlanCoverageInstructions() {
        let reviewer = AgentProfile(
            id: AgentProfileStore.reviewerAgentID.uuidString,
            name: AgentProfileStore.reviewerAgentName,
            tools: []
        )
        let plan = TerminalSessionPlan(
            originalGoal: "Add plan-aware review",
            consolidatedText: "1. Persist the plan.\n2. Verify current files.",
            createdAt: Date(timeIntervalSince1970: 100),
            isApproved: true
        )

        let prompt = TerminalChat.reviewDelegationPrompt(
            scope: "",
            reviewer: reviewer,
            changeSummary: nil,
            approvedPlan: plan
        )

        #expect(prompt.contains("Approved plan under verification:"))
        #expect(prompt.contains("Original goal: Add plan-aware review"))
        #expect(prompt.contains("1. Persist the plan.\n2. Verify current files."))
        #expect(prompt.contains("at least one dedicated Reviewer for plan coverage"))
        #expect(prompt.contains("current state of the files implicated by the plan"))
        #expect(prompt.contains("not merely the latest diff"))
        #expect(prompt.contains("implemented, validated, unverified, failed, deviated, cancelled, or blocked"))
        #expect(prompt.contains("A task marked completed is an assertion to verify"))
        #expect(prompt.contains("awaiting_validation is not completed"))
        #expect(prompt.contains("file:line references whenever available"))
        #expect(prompt.contains("No tracked file-change summary is available"))
        #expect(prompt.contains("This is coverage-only mode"))
        #expect(!prompt.contains("Session change surface:"))
    }

    @Test
    func reviewPromptIgnoresUnapprovedPlanAndPreservesLegacyPrompt() {
        let reviewer = AgentProfile(
            id: AgentProfileStore.reviewerAgentID.uuidString,
            name: AgentProfileStore.reviewerAgentName,
            tools: []
        )
        let summary = TurnFileChangeSummary(entries: [])
        let unapprovedPlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan",
            isApproved: false
        )

        let withoutPlan = TerminalChat.reviewDelegationPrompt(
            scope: "",
            reviewer: reviewer,
            changeSummary: summary
        )
        let withUnapprovedPlan = TerminalChat.reviewDelegationPrompt(
            scope: "",
            reviewer: reviewer,
            changeSummary: summary,
            approvedPlan: unapprovedPlan
        )

        #expect(withUnapprovedPlan == withoutPlan)
        #expect(!withUnapprovedPlan.contains("Approved plan under verification"))
    }

    @Test
    func approvedPlanWithChangesDefinesIndependentReviewTasksBeforeParallelDelegation() {
        let reviewer = AgentProfile(
            id: AgentProfileStore.reviewerAgentID.uuidString,
            name: AgentProfileStore.reviewerAgentName,
            tools: []
        )
        let prompt = TerminalChat.reviewDelegationPrompt(
            scope: "",
            reviewer: reviewer,
            changeSummary: TurnFileChangeSummary(entries: []),
            approvedPlan: TerminalSessionPlan(
                originalGoal: "goal",
                consolidatedText: "plan",
                isApproved: true
            )
        )

        #expect(prompt.contains("separate code-quality/correctness Reviewers"))
        #expect(prompt.contains("first add one independent review task per Reviewer"))
        #expect(prompt.contains("tasks.list with runnableOnly=true"))
        #expect(prompt.contains("pass each taskID to agent.create"))
        #expect(prompt.contains("dedicated Reviewer for plan coverage"))
    }

    @Test
    func reviewRunsCoverageOnlyForApprovedPlanAndKeepsItActive() async throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan",
            isApproved: true
        )
        terminal.activePlan = plan

        for _ in 0..<2 {
            let action = await terminal.handleReviewCommand("/review")
            guard case let .runHiddenPrompt(prompt, purpose) = action else {
                Issue.record("An approved plan should allow coverage-only review")
                return
            }
            #expect(prompt.contains("Approved plan under verification"))
            #expect(purpose == .review)
            #expect(terminal.activePlan == plan)
        }
    }

    @Test
    func reviewWithoutChangesIgnoresUnapprovedPlan() async throws {
        let terminal = try makeTerminal()
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan",
            isApproved: false
        )

        let action = await terminal.handleReviewCommand("/review")

        if case .continueChat = action {
            #expect(terminal.activePlan?.isApproved == false)
        } else {
            Issue.record("An unapproved plan must not enable coverage-only review")
        }
    }

    @Test
    func manualTaskGraphEnablesCoverageOnlyReview() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.sessionRunner.taskOrchestrator.createGraph(
            sessionID: terminal.sessionID,
            id: "manual-review",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "Verify manual work")]
        )

        let action = await terminal.handleReviewCommand("/review")
        guard case let .runHiddenPrompt(prompt, purpose) = action else {
            Issue.record("A manual task graph should enable coverage-only review")
            return
        }
        #expect(purpose == .review)
        #expect(prompt.contains("No approved plan is attached"))
        #expect(prompt.contains("task=task-a status=pending"))
        #expect(prompt.contains("task-graph coverage"))
    }

    @Test
    func reviewPromptTreatsTaskStatusAndEvidenceAsClaims() {
        let now = Date(timeIntervalSince1970: 100)
        let plan = TerminalSessionPlan(
            id: "plan-review",
            originalGoal: "Verify implementation",
            consolidatedText: "Implement and validate.",
            isApproved: true,
            points: [TerminalSessionPlanPoint(id: "plan-review-1", text: "Implement")]
        )
        let graph = TaskGraphSnapshot(
            id: "plan-review",
            source: .plan(planID: "plan-review"),
            state: .completed,
            tasks: [
                TaskRecord(
                    id: "plan-review-1",
                    title: "Implement",
                    order: 1,
                    status: .completed,
                    attempts: [
                        TaskAttempt(
                            id: "attempt-1",
                            ordinal: 1,
                            agentID: "agent-1",
                            executor: .subAgent,
                            status: .completed,
                            startedAt: now,
                            finishedAt: now,
                            output: "claimed implementation"
                        )
                    ],
                    result: TaskResult(
                        output: "claimed implementation",
                        evidence: [TaskEvidence(kind: "test", summary: "claimed green test")]
                    ),
                    createdAt: now,
                    updatedAt: now
                )
            ],
            createdAt: now,
            updatedAt: now
        )

        let prompt = TerminalChat.reviewDelegationPrompt(
            scope: "",
            reviewer: AgentProfileStore.defaultProfiles().first {
                TerminalChat.isReviewerProfile($0)
            } ?? AgentProfileStore.defaultProfiles()[0],
            changeSummary: nil,
            approvedPlan: plan,
            taskGraph: graph
        )

        #expect(prompt.contains("task=plan-review-1 status=completed"))
        #expect(prompt.contains("attempt #1"))
        #expect(prompt.contains("claimed green test"))
        #expect(prompt.contains("completed is an assertion to verify"))
        #expect(prompt.contains("implemented, validated, unverified"))
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-review-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.selectedToolKeys.insert("sub-agents")
        return terminal
    }
}
