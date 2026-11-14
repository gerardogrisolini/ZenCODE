//
//  AgentProfileRoleCommandTests.swift
//  ZenCODE
//
//  `/plan` and `/review` delegate to the profiles with the planner/reviewer
//  role that are visible to the project, and stop when there is none.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct AgentProfileRoleCommandTests {
    private typealias Roles = AgentProfileRoleTestSupport

    private static var agents: [AgentProfile] {
        [Roles.developer, Roles.systemReviewer, Roles.systemPlanner, Roles.customReviewer, Roles.pluto]
    }

    /// Runs `body` with a throwaway support directory and workspace; `select`
    /// saves the project selection first when it is not `nil`.
    private static func withProject(
        agents: [AgentProfile] = Self.agents,
        selecting selection: [AgentProfile]?,
        _ body: @escaping @Sendable @ChatSessionActor (TerminalChat, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-role-commands-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable @ChatSessionActor in
            if let selection {
                try ProjectAgentSelectionStore.save(
                    agentIDs: selection.map(\.id),
                    workspaceRootURL: workspace
                )
            }
            let terminal = TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "remote-community/test",
                    availableAgents: agents,
                    workingDirectory: workspace
                ),
                stdinIsTerminal: false
            )
            terminal.selectedToolKeys.insert("sub-agents")
            try await body(terminal, workspace)
        }
    }

    @ChatSessionActor
    private static func approvePlan(on terminal: TerminalChat) {
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan",
            isApproved: true
        )
    }

    @ChatSessionActor
    private static func hiddenPrompt(_ action: TerminalSubmittedLineAction) -> String? {
        guard case let .runHiddenPrompt(prompt, _) = action else { return nil }
        return prompt
    }

    @ChatSessionActor
    private static func isContinueChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action { return true }
        return false
    }

    @Test
    func reviewAndPlanStopWhenTheProjectAssociatesNoProfileWithTheRole() async throws {
        try await Self.withProject(selecting: [Roles.developer]) { terminal, _ in
            Self.approvePlan(on: terminal)

            #expect(Self.isContinueChat(await terminal.handleReviewCommand("/review")))
            #expect(Self.isContinueChat(await terminal.handlePlanCommand("/plan ship roles")))
            #expect(terminal.chatSession.planBrainstorming == nil)
        }
    }

    @Test
    func reviewDelegatesToACustomReviewerWithAnyName() async throws {
        try await Self.withProject(selecting: [Roles.developer, Roles.customReviewer]) { terminal, _ in
            Self.approvePlan(on: terminal)

            let prompt = try #require(Self.hiddenPrompt(await terminal.handleReviewCommand("/review")))
            #expect(prompt.contains("role \"Reviewer\" and profile \"\(Roles.customReviewer.id)\";"))
            #expect(!prompt.contains("profile \"reviewer\""))
            #expect(!prompt.contains("any of them is acceptable"))
        }
    }
}
