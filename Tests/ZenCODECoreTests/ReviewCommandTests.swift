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
    func reviewerToolAllowlistExcludesGitAndMemory() {
        let reviewer = AgentProfile(
            id: AgentProfileStore.reviewerAgentID.uuidString,
            name: AgentProfileStore.reviewerAgentName,
            tools: [
                "local.readFile",
                "search.grep",
                "git.diff",
                "memory.read"
            ]
        )

        let tools = TerminalChat.reviewerSubAgentToolNames(for: reviewer)

        #expect(tools.contains("local.readFile"))
        #expect(tools.contains("search.grep"))
        #expect(!tools.contains("git.diff"))
        #expect(!tools.contains("memory.read"))
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
    }
}
