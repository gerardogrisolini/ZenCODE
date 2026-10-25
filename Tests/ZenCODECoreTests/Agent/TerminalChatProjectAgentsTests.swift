//
//  TerminalChatProjectAgentsTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatProjectAgentsTests {
    @Test
    func menuHelpExplainsProjectToggleAndEnterUsesAgent() {
        #expect(TerminalChat.projectAgentMenuHelpLines == [
            "↑/↓ move · Space/X toggle agents · A all · N none · Enter use agent · Esc/Q cancel"
        ])
    }

    @Test
    func projectNameIsTheFolderNameOrThePathAtTheFilesystemRoot() {
        #expect(TerminalChat.projectDisplayName(URL(fileURLWithPath: "/tmp/ZenCODE-demo", isDirectory: true)) == "ZenCODE-demo")
        #expect(TerminalChat.projectDisplayName(URL(fileURLWithPath: "/tmp/ZenCODE-demo/sub/..")) == "ZenCODE-demo")
        #expect(TerminalChat.projectDisplayName(URL(fileURLWithPath: "/", isDirectory: true)) == "/")
    }

    @Test
    func menuTicksOnlyTheSystemProfilesWithoutASavedSelection() {
        let custom = AgentProfile(id: UUID().uuidString, name: "Brutta merda", role: .reviewer)
        let agents = AgentProfileStore.defaultProfiles() + [custom]

        #expect(
            TerminalChat.projectAgentMenuInitialAssociation(agents, savedSelection: nil)
                == Set(AgentProfileStore.defaultProfiles())
        )
        #expect(
            TerminalChat.projectAgentMenuInitialAssociation(
                agents,
                savedSelection: [custom.id.lowercased(), AgentProfileRole.planner.rawValue]
            ) == Set(agents.filter { $0.id == custom.id || $0.id == AgentProfileRole.planner.rawValue })
        )
        #expect(TerminalChat.projectAgentMenuInitialAssociation(agents, savedSelection: []).isEmpty)
        // A selection saved with the former UUIDs of the system profiles
        // matches nothing: no profile is ticked.
        #expect(
            TerminalChat.projectAgentMenuInitialAssociation(
                agents,
                savedSelection: ["00000000-0000-0000-0000-000000000010"]
            ).isEmpty
        )
    }

    @Test
    @TerminalChatActor
    func savedSessionWithAFormerSystemProfileIDRestoresLikeADeletedProfile() throws {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-stale-profile-ids", isDirectory: true)
            ),
            stdinIsTerminal: false
        )
        func savedSession(agentID: String?, agentName: String?) -> TerminalSavedSession {
            TerminalSavedSession(
                name: "stale", sessionID: "stale-session", cacheKey: nil,
                workingDirectoryPath: "/tmp/ZenCODE-stale-profile-ids", createdAt: Date(), savedAt: Date(),
                modelID: nil, agentID: agentID, agentName: agentName, selectedTools: [],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: nil,
                history: [],
                checkpointTree: SessionCheckpointTree.fromLinearHistory([], sessionID: "stale-session")
            )
        }

        // The former UUID matches no profile; the saved name still does.
        let byName = try terminal.restoredAgent(for: savedSession(
            agentID: "00000000-0000-0000-0000-000000000012",
            agentName: "Developer"
        ))
        #expect(byName?.id == AgentProfileRole.developer.rawValue)
        // Neither matches: the session restores without an agent, as for a
        // profile that no longer exists.
        #expect(try terminal.restoredAgent(for: savedSession(
            agentID: "00000000-0000-0000-0000-000000000010",
            agentName: "Renamed Reviewer"
        )) == nil)
    }

    @Test
    func associationMessageListsTheAssociatedProfilesOrSaysThereAreNone() {
        let message = TerminalChat.renderProjectAgentAssociation(
            associated: [
                AgentProfile(id: "a", name: "Developer", role: .developer),
                AgentProfile(id: "b", name: "Reviewer", role: .reviewer),
            ],
            projectName: "Demo"
        )
        #expect(message == "Project agents for Demo: Developer, Reviewer.\n")

        let none = TerminalChat.renderProjectAgentAssociation(associated: [], projectName: "Demo")
        #expect(none.contains("No agent profile is associated with project Demo"))
        #expect(none.contains("/agents"))
        #expect(none.hasSuffix("\n"))
    }

    @Test
    func agentsCommandDescriptorDocumentsTheProjectAssociation() throws {
        let descriptor = try #require(
            TerminalChat.visibleCommandDescriptors(builderAgentEnabled: false, telegramEnabled: false)
                .first { $0.command == "/agents" }
        )
        #expect(descriptor.summary.contains("project"))
        #expect(descriptor.help.contains("Space/X"))
        #expect(descriptor.help.contains("sub-agents"))
        #expect(descriptor.help.contains("Enter"))
    }
}
