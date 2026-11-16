//
//  ChatSessionSelectionTests+ProjectAgents.swift
//  ZenCODE
//
//  The second part of the selection tests: the project agents association,
//  the workspace access a selection needs, and the agent selection command
//  (`/agents`), with the helpers only these tests use.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension ChatSessionSelectionTests {
    // MARK: - Project agents

    private var projectAgents: ChatTestCatalog {
        .hosted(agents: [Fixtures.developer, Fixtures.reviewer, Fixtures.reporter])
    }

    private func projectAgentsFile(_ harness: ChatManagementHarness) -> URL {
        ProjectAgentSelectionStore.manifestURL(workspaceRootURL: harness.workspace)
    }

    @Test
    func aChangedAssociationIsSavedAndTheActiveAgentKeepsItsSession() async throws {
        try await withChatHarness(
            catalog: projectAgents,
            hostCapabilities: [.focusedMultipleChoice]
        ) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            controller.savedSessionState.systemPromptOverride = "A stale prompt."
            let developerID = ChatSessionController.agentChoiceID(Fixtures.developer)
            let reviewerID = ChatSessionController.agentChoiceID(Fixtures.reviewer)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: harness.workspace) == nil)
            await harness.host.answerChooseManyWithFocus(
                ChatFocusedChoice(selectedIDs: [developerID, reviewerID], focusedID: developerID)
            )

            let outcome = try await controller.chooseProjectAgents()

            let projectName = harness.workspace.lastPathComponent
            #expect(await harness.host.interactions == [
                .chooseManyWithFocus(
                    title: "Agent profiles · project: \(projectName)",
                    items: [
                        ChatChoiceItem(
                            id: developerID,
                            title: "Developer",
                            detail: "General software development; the default agent",
                            isCurrent: true
                        ),
                        ChatChoiceItem(
                            id: reviewerID,
                            title: "Reviewer",
                            detail: "/review delegates to it"
                        ),
                        ChatChoiceItem(
                            id: ChatSessionController.agentChoiceID(Fixtures.reporter),
                            title: "Reporter",
                            detail: ChatSessionNoticeText.agentDetail(Fixtures.reporter)
                        ),
                    ],
                    // A project without a saved selection starts with the system
                    // profiles ticked.
                    selectedIDs: [developerID],
                    focusedID: developerID,
                    toggleLabel: "agents",
                    confirmLabel: "use agent"
                ),
            ])
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: harness.workspace)
                == Set([Fixtures.developer, Fixtures.reviewer]
                    .map(ProjectAgentSelectionStore.selectionKey(for:))))
            #expect(await harness.presenter.notices == [
                .projectAgentsAssociated(
                    agents: [Fixtures.developer, Fixtures.reviewer],
                    projectName: projectName
                ),
            ])
            // Same agent: the prompt is rebuilt in place, the conversation kept.
            #expect(outcome == ChatSelectionOutcome(change: .sessionUpdated))
            #expect(await harness.callNames() == ["updateSessionOptions"])
            #expect(controller.savedSessionState.systemPromptOverride == nil)
            #expect(controller.selection.agent == Fixtures.developer)
        }
    }

    @Test
    func aChangedActiveRowSwitchesTheAgentWithoutWritingAnUnchangedAssociation() async throws {
        try await withChatHarness(
            catalog: projectAgents,
            hostCapabilities: [.focusedMultipleChoice]
        ) { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            let developerID = ChatSessionController.agentChoiceID(Fixtures.developer)
            let reviewerID = ChatSessionController.agentChoiceID(Fixtures.reviewer)
            await harness.host.answerChooseManyWithFocus(
                ChatFocusedChoice(selectedIDs: [developerID], focusedID: reviewerID)
            )

            let outcome = try await controller.chooseProjectAgents()

            #expect(outcome == ChatSelectionOutcome(
                change: .sessionRecreated,
                notices: [.agentSwitched(Fixtures.reviewer)]
            ))
            #expect(controller.selection.agent == Fixtures.reviewer)
            // Confirming an unchanged association writes no file.
            #expect(!FileManager.default.fileExists(
                atPath: projectAgentsFile(harness).path
            ))
            #expect(await harness.presenter.notices.isEmpty)
            #expect(await harness.callNames() == [
                "shutdownBackendKeepingExternalTools",
                "clearTaskGraphs",
                "createSession",
                "updatePromptSkillSelection",
                "preloadModel",
            ])
        }
    }

    // MARK: - Workspace access

    @Test
    func deniedWorkspaceAccessDeselectsTheWorkspaceToolsAndSaysSo() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell", "files", "sub-agents"]
            await harness.host.answerWorkspaceAccess(false)

            await controller.ensureWorkspaceAccess()

            let request = ChatWorkspaceAccessRequest(
                workspaceURL: harness.workspace,
                toolTitles: ["Shell", "Files"]
            )
            // Only the groups that need the folder are dropped.
            #expect(controller.selection.toolKeys == ["sub-agents"])
            #expect(await harness.host.interactions == [.requestWorkspaceAccess(request)])
            #expect(await harness.presenter.notices == [.workspaceAccessDenied(request)])
            #expect(await harness.presenter.states.last?.selection.toolKeys == ["sub-agents"])
        }
    }

    @Test
    func grantedWorkspaceAccessAndToolsThatNeedNoFolderChangeNothing() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell", "files"]
            await harness.host.answerWorkspaceAccess(true)

            await controller.ensureWorkspaceAccess()

            #expect(controller.selection.toolKeys == ["shell", "files"])
            #expect(await harness.host.interactions.count == 1)
            #expect(await harness.presenter.events.isEmpty)

            // No selected group reaches the folder, so the host is not asked.
            controller.selection.toolKeys = ["sub-agents"]
            await harness.clearRecords()
            await controller.ensureWorkspaceAccess()
            #expect(await harness.host.interactions.isEmpty)
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func deniedWorkspaceAccessDuringAToolSelectionRemovesTheKeysFromTheSession() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            await harness.host.answerWorkspaceAccess(false)

            let outcome = await controller.selectTools(keys: ["files", "sub-agents"])

            #expect(controller.selection.toolKeys == ["sub-agents"])
            #expect(await harness.presenter.notices.contains(
                .workspaceAccessDenied(
                    ChatWorkspaceAccessRequest(workspaceURL: harness.workspace, toolTitles: ["Files"])
                )
            ))
            // The session never receives the tools the platform refused.
            let digest = try #require(await harness.runtime.calls.first?.digest)
            #expect(try #require(digest.allowedToolNames).contains("local.readFile") == false)
            guard case let .activeTools(summary) = try #require(outcome.notices.first) else {
                Issue.record("The closing notice reports the active tools")
                return
            }
            #expect(!summary.groups.map(\.title).contains("Files"))
        }
    }

    @Test
    func deniedWorkspaceAccessDuringAnAgentSwitchDeselectsTheAgentTools() async throws {
        let shellAgent = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000010",
            name: "Shell Agent",
            role: .developer,
            tools: ["shell"]
        )
        try await withChatHarness(
            catalog: .hosted(agents: [Fixtures.developer, shellAgent])
        ) { harness in
            await harness.host.answerWorkspaceAccess(false)

            let outcome = try await harness.controller.selectAgent(shellAgent)

            #expect(outcome.notices == [.agentSwitched(shellAgent)])
            #expect(harness.controller.selection.toolKeys.isEmpty)
            #expect(await harness.presenter.notices == [
                .workspaceAccessDenied(
                    ChatWorkspaceAccessRequest(workspaceURL: harness.workspace, toolTitles: ["Shell"])
                ),
            ])
        }
    }

    // MARK: - Agent

    @Test
    func selectingAnAgentResetsThePlanAndTheTaskGraphButKeepsTheConversation() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID
            controller.activePlan = TerminalSessionPlan(
                id: "plan-to-reset",
                originalGoal: "Fix the parser",
                consolidatedText: "1. Read the parser.",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isApproved: true,
                points: [TerminalSessionPlanPoint(id: "plan-to-reset-1", text: "Read the parser")]
            )
            controller.pendingPlanApprovalPlanID = "plan-to-reset"
            controller.savedSessionState.systemPromptOverride = "A stale prompt."
            try await harness.runtime.seedTaskGraph(Fixtures.taskGraph(id: "graph-1"), sessionID: sessionID)
            #expect(try await harness.runtime.taskGraphSnapshot(sessionID: sessionID, graphID: nil)?.id == "graph-1")
            await harness.clearRecords()

            let outcome = try await controller.selectAgent(Fixtures.reviewer)

            #expect(outcome == ChatSelectionOutcome(
                change: .sessionRecreated,
                notices: [.agentSwitched(Fixtures.reviewer)]
            ))
            #expect(ChatSessionNoticeText.text(for: try #require(outcome.notices.first))
                == "Switched to agent: Reviewer. Plan and task graph reset; conversation kept.\n")
            #expect(controller.selection.agent == Fixtures.reviewer)
            #expect(controller.activePlan == nil)
            #expect(controller.pendingPlanApprovalPlanID == nil)
            #expect(controller.savedSessionState.systemPromptOverride == nil)
            #expect(try await harness.runtime.taskGraphSnapshot(sessionID: sessionID, graphID: nil) == nil)

            // The conversation stays in the controller and in the new session.
            #expect(controller.history.map(\.content) == Fixtures.conversation.map(\.content))
            #expect(controller.transcript.map(\.content) == Fixtures.conversation.map(\.content))
            let calls = await harness.runtime.calls
            #expect(calls.map(\.name) == [
                "shutdownBackendKeepingExternalTools",
                "clearTaskGraphs",
                "createSession",
                "updatePromptSkillSelection",
                "preloadModel",
            ])
            #expect(calls[1] == .clearTaskGraphs(sessionID: sessionID))
            let created = try #require(calls[2].digest)
            #expect(created.sessionID == sessionID)
            #expect(created.agentID == Fixtures.reviewer.id)
            #expect(created.historyContents == Fixtures.conversation.map(\.content))
            #expect(await harness.presenter.states.last?.selection.agent == Fixtures.reviewer)
        }
    }

    @Test
    func selectingAnAgentKeepsAModelChosenThroughModelsAndOtherwiseFallsBack() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            // A model chosen explicitly is session state, not the agent's.
            controller.selection.modelIDOverride = Fixtures.beta.id
            controller.selection.thinkingOverride = .high
            _ = try await controller.selectAgent(Fixtures.reviewer)
            #expect(controller.selection.modelIDOverride == Fixtures.beta.id)
            #expect(controller.selection.thinkingOverride == .high)
            let created = try #require(await harness.runtime.calls.first { $0.name == "createSession" }?.digest)
            #expect(created.modelID == Fixtures.beta.id)
            #expect(created.thinkingSelection == .high)

            // Without one, a hosted session falls back to the launch model and
            // forgets a stale level.
            controller.selection.modelIDOverride = nil
            controller.selection.thinkingOverride = .high
            _ = try await controller.selectAgent(Fixtures.developer)
            #expect(controller.selection.modelIDOverride == nil)
            #expect(controller.selection.thinkingOverride == nil)
        }
    }

    @Test
    func theNewAgentBringsItsToolsAndSkills() async throws {
        let skilled = AgentProfile(
            id: "BBBBBBBB-0000-0000-0000-000000000011",
            name: "Skilled",
            role: .developer,
            tools: ["files"],
            skills: [AgentProfileSkill(name: "alpha-skill")]
        )
        try await withChatHarness(
            catalog: .hosted(agents: [Fixtures.developer, skilled])
        ) { harness in
            let controller = harness.controller
            let alpha = try harness.installSkills("alpha-skill", "beta-skill")[0]

            _ = try await controller.selectAgent(skilled)

            #expect(controller.selection.toolKeys == ["files"])
            #expect(controller.selection.skillNames == [alpha.canonicalName])
            let calls = await harness.runtime.calls
            let created = try #require(calls.first { $0.name == "createSession" }?.digest)
            let allowed = try #require(created.allowedToolNames)
            #expect(allowed.contains("local.readFile"))
            #expect(!allowed.contains("local.exec"))
            // The skills reach the new session before the model loads.
            #expect(calls.contains(
                .updatePromptSkillSelection(skillNames: [alpha.canonicalName], sessionID: controller.sessionID)
            ))
            #expect(await harness.runtime.promptSkills(for: controller.sessionID).map(\.canonicalName) == [alpha.canonicalName])
        }
    }

    @Test
    func anAgentIsSelectedByNumberOrByNameAndAnUnknownOneThrows() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            let byNumber = try await controller.selectAgent(rawSelection: "2")
            #expect(byNumber.notices == [.agentSwitched(Fixtures.reviewer)])

            let byName = try await controller.selectAgent(rawSelection: "  DEVELOPER ")
            #expect(byName.notices == [.agentSwitched(Fixtures.developer)])
            #expect(controller.selection.agent == Fixtures.developer)

            await harness.clearRecords()
            let error = await capturedError { try await controller.selectAgent(rawSelection: "nobody") }
            guard case let .unknownAgent(name) = try #require(error as? TerminalAgentSelectionError) else {
                Issue.record("An unknown agent throws unknownAgent")
                return
            }
            #expect(name == "nobody")
            #expect(await harness.runtime.calls.isEmpty)
            #expect(controller.selection.agent == Fixtures.developer)
        }
    }
}
