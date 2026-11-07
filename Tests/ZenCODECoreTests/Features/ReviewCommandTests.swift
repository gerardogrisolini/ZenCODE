//
//  ReviewCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/06/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
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
            id: AgentProfileRole.reviewer.rawValue,
            name: AgentProfileStore.reviewerAgentName,
            role: .reviewer,
            tools: []
        )

        let prompt = TerminalChat.reviewDelegationPrompt(
            scope: "focus on errors",
            reviewer: reviewer,
            changeSummary: summary
        )

        #expect(prompt.contains("Session change surface:"))
        #expect(prompt.contains("- modified Sources/Example.swift  +2 -1"))
        #expect(prompt.contains("No diffs are included. Read the current content of each listed file"))
        #expect(!prompt.contains("diff --git a/Sources/Example.swift b/Sources/Example.swift"))
        #expect(!prompt.contains("+line"))
        #expect(prompt.contains("Review focus requested by the user: focus on errors"))
        #expect(prompt.contains("Apply this focus only within the tracked file changes"))
        #expect(prompt.contains("profile \"\(reviewer.id)\""))
        #expect(!prompt.contains("toolNames"))
        #expect(!prompt.contains("git status"))
        #expect(!prompt.contains("recent log"))
        #expect(!prompt.contains("project journal"))
        #expect(!prompt.contains("project memory"))
        #expect(!prompt.contains("memory tools"))
        #expect(!prompt.contains("Approved plan under verification"))
        #expect(!prompt.contains("done, partial, missing, or deviated"))
    }

    @Test
    func approvedPlanWithChangesDefinesIndependentReviewTasksBeforeParallelDelegation() {
        let reviewer = AgentProfile(
            id: AgentProfileRole.reviewer.rawValue,
            name: AgentProfileStore.reviewerAgentName,
            role: .reviewer,
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
        #expect(prompt.contains("canonical agent.create"))
        #expect(prompt.contains("`agents` item's `taskID` field"))
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

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
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
