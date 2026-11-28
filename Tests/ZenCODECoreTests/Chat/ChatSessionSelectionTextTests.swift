//
//  ChatSessionSelectionTextTests.swift
//  ZenCODE
//
//  The tests of the texts of the selection notices and of the active-tool
//  count, as the terminal wrote them before they moved to
//  `ChatSessionNoticeText`.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Texts

/// The active-tool count and the channel of the selection notices, as the
/// terminal wrote them before they moved to `ChatSessionNoticeText`.
@Suite("Chat session selection texts")
struct ChatSessionSelectionTextTests {
    private typealias Fixtures = ChatTestFixtures

    private func text(_ notice: ChatSessionNotice) -> String {
        ChatSessionNoticeText.text(for: notice)
    }

    private static let skillOne = PromptSkill(
        canonicalName: "release-review",
        title: "Release Review",
        summary: "Review release changes.",
        promptBody: "Body",
        sourceHash: "hash-one"
    )

    // MARK: Tools and skills

    @Test
    func theActiveToolGroupsAreCountedAsTheTerminalCountedThem() {
        let items = TerminalToolSelectionCatalog.items(featureStatuses: [])
        let summary = ChatActiveToolsSummary(
            toolNames: ["local.exec", "exec.job", "local.read", "skills.list", "skills.read"],
            items: items,
            selectedKeys: ["shell", "files"]
        )

        #expect(text(.activeTools(summary)) == "Active tools: Shell (2), Files (1), Skills (2)\n")
        // Feature-management tools are never listed, and no tool means none.
        let hidden = ChatActiveToolsSummary(
            toolNames: Array(AgentProfileStore.featureManagementToolNames),
            items: items,
            selectedKeys: ["shell", "files"]
        )
        #expect(text(.activeTools(hidden)) == "Active tools: none\n")
    }

    @Test
    func eachNoticeIsWrittenInTheToneTheTerminalWroteItIn() {
        let request = ChatWorkspaceAccessRequest(
            workspaceURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            toolTitles: ["Shell"]
        )
        let failures: [ChatSessionNotice] = [
            .operationFailed(description: "boom"),
            .projectAgentsSaveFailed(description: "disk full"),
            .skillInstallSourceRequired,
            .requiresInteractiveHost(.skillUninstall),
        ]
        let system: [ChatSessionNotice] = [
            .modelSelected(Fixtures.beta, thinking: nil),
            .modelUnchanged,
            .noCurrentModel,
            .thinkingNotSupported(model: Fixtures.alpha),
            .thinkingUnchanged,
            .selectedAgent(nil),
            .agentSwitched(Fixtures.reviewer),
            .toolSelectionUsage,
            .skillSelectionUsage,
            .noPromptSkillsInstalled,
            .skillInstalled(Self.skillOne),
            .workspaceAccessDenied(request),
            .requiresInteractiveHost(.modelSelection(models: [Fixtures.alpha], selectedModelID: nil)),
            .requiresInteractiveHost(.skillSelection(selected: [])),
        ]

        #expect(failures.allSatisfy { $0.channel == .failure })
        #expect(system.allSatisfy { $0.channel == .system })
    }
}
