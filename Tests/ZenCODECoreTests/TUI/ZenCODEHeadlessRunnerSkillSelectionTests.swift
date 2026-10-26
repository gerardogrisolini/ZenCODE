//
//  ZenCODEHeadlessRunnerSkillSelectionTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

/// A headless turn (`zen -p ...`, `/cron` jobs) never enters
/// `TerminalChat.run()`, so the selected agent profile's prompt skills must
/// still reach the session. They always come from the profile: the
/// `--skills` / `ZENCODE_AGENT_SKILLS` selection only applies to the
/// interactive startup and is ignored here.
@Suite
struct ZenCODEHeadlessRunnerSkillSelectionTests {
    private typealias Support = ProjectAgentSelectionTestSupport

    private static let profile = AgentProfile(
        id: "BBBBBBBB-0000-0000-0000-000000000001",
        name: "Skilled",
        role: .developer,
        skills: [AgentProfileSkill(id: "alpha", canonicalName: "alpha")]
    )

    @Test
    func headlessSessionSelectsTheProfileSkills() async throws {
        let names = try await Self.headlessSelectedSkillNames(initialSkillSelection: nil)
        #expect(names == ["alpha"])
    }

    @Test
    func initialSkillSelectionDoesNotChangeTheHeadlessProfileSkills() async throws {
        for selection in ["beta", "all", "none", "missing-skill"] {
            let names = try await Self.headlessSelectedSkillNames(initialSkillSelection: selection)
            #expect(names == ["alpha"], "--skills \(selection) must be ignored in headless mode")
        }
    }

    private static func headlessSelectedSkillNames(
        initialSkillSelection: String?
    ) async throws -> [String] {
        try await Support.withTemporaryProjectAsync { support, workspace in
            let skillsRoot = support.appendingPathComponent("skills", isDirectory: true)
            try writeSkill(named: "alpha", in: skillsRoot)
            try writeSkill(named: "beta", in: skillsRoot)
            return try await headlessSelectedSkillNames(
                initialSkillSelection: initialSkillSelection,
                workspace: workspace
            )
        }
    }

    @TerminalChatActor
    private static func headlessSelectedSkillNames(
        initialSkillSelection: String?,
        workspace: URL
    ) async throws -> [String] {
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            agentName: profile.name,
            availableAgents: AgentProfileStore.defaultProfiles() + [profile],
            runMode: .headless,
            workingDirectory: workspace,
            initialSkillSelection: initialSkillSelection
        )
        let sessionRunner = AgentCoreSessionRunner(
            backendFactory: { _, _ in throw UnexpectedBackendCreation() }
        )
        let session = await ZenCODEHeadlessRunner.makeSession(
            configuration: configuration,
            sessionRunner: sessionRunner
        )
        return session.promptSkills.map(\.canonicalName).sorted()
    }

    private static func writeSkill(named name: String, in root: URL) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: The \(name) test skill.
        ---

        # \(name)

        Follow the \(name) instructions.
        """
        .write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private struct UnexpectedBackendCreation: Error {}
