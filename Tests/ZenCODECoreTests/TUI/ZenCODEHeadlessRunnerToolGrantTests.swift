//
//  ZenCODEHeadlessRunnerToolGrantTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

/// A headless turn (`zen -p ...`, `/cron` jobs) never enters
/// `TerminalChat.run()`, so the selected agent profile must still reach the
/// session's tool allowlist. Without it the model only sees the intrinsic
/// prompt-skill tools.
@Suite
struct ZenCODEHeadlessRunnerToolGrantTests {
    private typealias Support = ProjectAgentSelectionTestSupport

    @Test
    func defaultDeveloperHeadlessSessionCarriesTheDeveloperToolGrant() async throws {
        try await Support.withTemporaryProjectAsync { _, workspace in
            let allowed = try await Self.headlessAllowedToolNames(
                agentName: nil,
                workspace: workspace
            )

            Self.expectBeyondIntrinsicSkillTools(allowed)
            // shell, files, text, memory and sub-agents of the Developer profile.
            for name in [
                "local.exec", "local.readFile", "text.wc",
                "memory.read", "agent.create", "tasks.create"
            ] {
                #expect(allowed.contains(name), "Developer headless session must allow \(name)")
            }
            #expect(!allowed.contains("feature.list"))
            #expect(allowed.isSuperset(of: Self.expectedCoreGrant(forAgentNamed: AgentProfileStore.developerAgentName)))
        }
    }

    // Organizer is a recommended profile only on macOS (see
    // `AgentProfileStore.defaultProfiles()`), so it cannot be selected by name
    // on other platforms.
    #if os(macOS)
    @Test
    func organizerHeadlessSessionCarriesTheOrganizerToolGrant() async throws {
        try await Support.withTemporaryProjectAsync { _, workspace in
            let allowed = try await Self.headlessAllowedToolNames(
                agentName: AgentProfileStore.organizerAgentName,
                workspace: workspace
            )

            Self.expectBeyondIntrinsicSkillTools(allowed)
            // memory and sub-agents of the Organizer profile.
            for name in ["memory.read", "agent.create", "tasks.create"] {
                #expect(allowed.contains(name), "Organizer headless session must allow \(name)")
            }
            // The Organizer has neither shell, files nor text tools.
            for name in ["local.exec", "local.readFile", "text.wc"] {
                #expect(!allowed.contains(name), "Organizer headless session must not allow \(name)")
            }
            #expect(allowed.isSuperset(of: Self.expectedCoreGrant(forAgentNamed: AgentProfileStore.organizerAgentName)))
        }
    }
    #endif

    @TerminalChatActor
    private static func headlessAllowedToolNames(
        agentName: String?,
        workspace: URL
    ) async throws -> Set<String> {
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            agentName: agentName,
            runMode: .headless,
            workingDirectory: workspace
        )
        let sessionRunner = AgentCoreSessionRunner(
            backendFactory: { _, _ in throw UnexpectedBackendCreation() }
        )
        let session = await ZenCODEHeadlessRunner.makeSession(
            configuration: configuration,
            sessionRunner: sessionRunner
        )
        return try #require(session.configuration.allowedToolNames)
    }

    /// The profile's own grant as the app path resolves it, plus the
    /// always-on prompt-skill tools. Optional feature packages are left out:
    /// whether they expand to tools depends on what is installed.
    private static func expectedCoreGrant(forAgentNamed name: String) -> Set<String> {
        let profile = AgentProfileStore.defaultProfiles().first { $0.name == name }
        let grant = (profile?.allowedToolNames() ?? []).filter {
            !$0.hasPrefix(TerminalToolSelectionCatalog.featurePackageKeyPrefix)
        }
        return AgentSessionComposition.allowedToolNamesIncludingIntrinsicSkillTools(grant)
    }

    private static func expectBeyondIntrinsicSkillTools(_ allowed: Set<String>) {
        #expect(!allowed.isEmpty)
        #expect(allowed.isSuperset(of: PromptSkillToolProvider.toolNames))
        #expect(!allowed.subtracting(PromptSkillToolProvider.toolNames).isEmpty)
    }
}

private struct UnexpectedBackendCreation: Error {}
