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
        _ body: @escaping @Sendable @TerminalChatActor (TerminalChat, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-role-commands-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable @TerminalChatActor in
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

    @TerminalChatActor
    private static func approvePlan(on terminal: TerminalChat) {
        terminal.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan",
            isApproved: true
        )
    }

    @TerminalChatActor
    private static func hiddenPrompt(_ action: TerminalSubmittedLineAction) -> String? {
        guard case let .runHiddenPrompt(prompt, _) = action else { return nil }
        return prompt
    }

    @TerminalChatActor
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
            #expect(terminal.planBrainstorming == nil)
        }
    }

    @Test
    func reviewAndPlanStopWithoutASavedSelectionWhenNoSystemProfileHasTheRole() async throws {
        try await Self.withProject(
            agents: [Roles.developer, Roles.customReviewer, Roles.pluto],
            selecting: nil
        ) { terminal, _ in
            Self.approvePlan(on: terminal)

            #expect(Self.isContinueChat(await terminal.handleReviewCommand("/review")))
            #expect(Self.isContinueChat(await terminal.handlePlanCommand("/plan ship roles")))
            #expect(terminal.planBrainstorming == nil)
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

    @Test
    func reviewOffersEveryAssociatedReviewerRoleProfile() async throws {
        try await Self.withProject(
            selecting: [Roles.developer, Roles.systemReviewer, Roles.customReviewer]
        ) { terminal, _ in
            Self.approvePlan(on: terminal)

            let prompt = try #require(Self.hiddenPrompt(await terminal.handleReviewCommand("/review")))
            #expect(prompt.contains("one of these profiles (any of them is acceptable)"))
            #expect(prompt.contains("\"reviewer\" (Reviewer)"))
            #expect(prompt.contains("\"\(Roles.customReviewer.id)\" (Brutta merda)"))
        }
    }

    @Test
    func reviewWithoutASavedSelectionUsesOnlyTheSystemReviewer() async throws {
        try await Self.withProject(selecting: nil) { terminal, _ in
            Self.approvePlan(on: terminal)

            let prompt = try #require(Self.hiddenPrompt(await terminal.handleReviewCommand("/review")))
            #expect(prompt.contains("role \"Reviewer\" and profile \"reviewer\";"))
            #expect(!prompt.contains(Roles.customReviewer.id))
        }
    }

    @Test
    func planDelegatesToACustomPlannerRoleProfile() async throws {
        try await Self.withProject(selecting: [Roles.developer, Roles.pluto]) { terminal, _ in
            let prompt = try #require(Self.hiddenPrompt(await terminal.handlePlanCommand("/plan ship roles")))
            #expect(prompt.contains("role \"Planner\", and profile \"\(Roles.pluto.id)\"."))
            #expect(!prompt.contains("profile \"planner\""))
            #expect(terminal.planBrainstorming?.goal == "ship roles")
        }
    }

    @Test
    func planReplyIsKeptPendingWhileTheProjectAssociatesNoPlanner() async throws {
        try await Self.withProject(selecting: nil) { terminal, workspace in
            var state = TerminalPlanBrainstormingState(goal: "ship roles")
            state.recordPlannerOutput(
                "Planner questions\n1. Which roles?",
                agentID: "planner-1",
                revision: 1
            )
            terminal.planBrainstorming = state

            try ProjectAgentSelectionStore.save(agentIDs: [Roles.developer.id], workspaceRootURL: workspace)
            let blocked = try #require(await terminal.handlePlanBrainstormingReply("All three."))
            #expect(Self.isContinueChat(blocked))
            #expect(terminal.planBrainstorming == state)

            try ProjectAgentSelectionStore.save(
                agentIDs: [Roles.developer.id, Roles.pluto.id],
                workspaceRootURL: workspace
            )
            let resumed = try #require(await terminal.handlePlanBrainstormingReply("All three."))
            let prompt = try #require(Self.hiddenPrompt(resumed))
            #expect(prompt.contains("agent id \"planner-1\""))
            #expect(prompt.contains("profile \"\(Roles.pluto.id)\""))
            #expect(terminal.planBrainstorming?.exchanges.count == 1)
        }
    }
}
