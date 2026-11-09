//
//  ChatSessionWorktreePromptTests.swift
//  ZenCODECoreTests
//
//  The Git worktree section of the session system prompt: composed by the
//  controller, the path of the terminal chat and of the app windows, right
//  after the working-directory section of the stable prefix, only when the
//  launch asked for a worktree (`--worktree`) and the session works in it.
//  The configurations are parsed from arguments alone, so no worktree is
//  created; every composition reads a temporary support directory.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct ChatSessionWorktreePromptTests {
    private static let worktreeHeading = "Git worktree:"

    @Test
    func theWorktreeSectionHasItsExactText() {
        #expect(SystemPromptBuilder.worktreeSection(name: "feature", path: "/tmp/wt/feature/app") == """
            Git worktree:
            - This working directory is the Git worktree "feature" on branch "feature" of the project repository. Commit on this branch; do not switch branches, do not run git worktree commands, and do not touch the main working tree.
            """)
    }

    @Test
    func theSectionFollowsTheWorkingDirectorySectionOnlyWithAWorktree() async throws {
        try await withWorkspaces { workspace, _ in
            let worktreeConfiguration = try AgentConfiguration.withoutPersistedConfiguration(
                arguments: ["zen", "--worktree", "feature", "--working-directory", workspace.path]
            )
            let worktree = try #require(worktreeConfiguration.worktree)
            #expect(worktree.name == "feature")

            let sections = await Self.promptSections(
                configuration: worktreeConfiguration,
                workingDirectory: worktreeConfiguration.workingDirectory
            )
            let workingDirectorySection = SystemPromptBuilder.workingDirectorySection(
                path: worktreeConfiguration.workingDirectory.path
            )
            let worktreeSection = SystemPromptBuilder.worktreeSection(
                name: "feature",
                path: worktree.directory.path
            )
            #expect(sections.systemPrompt.contains(workingDirectorySection + "\n\n" + worktreeSection))
            #expect(sections.systemPrompt.components(separatedBy: Self.worktreeHeading).count == 2)
            #expect(!sections.dynamicContext.contains(Self.worktreeHeading))

            // The configuration the session runs with carries it too.
            let configuration = await Self.sessionConfiguration(
                configuration: worktreeConfiguration,
                workingDirectory: worktreeConfiguration.workingDirectory
            )
            #expect(configuration.systemPrompt?.contains(worktreeSection) == true)
            #expect(configuration.dynamicContext?.contains(Self.worktreeHeading) == false)

            // Without `--worktree` the prompt has no such section.
            let plainConfiguration = try AgentConfiguration.withoutPersistedConfiguration(
                arguments: ["zen", "--working-directory", workspace.path]
            )
            #expect(plainConfiguration.worktree == nil)
            let plain = await Self.promptSections(
                configuration: plainConfiguration,
                workingDirectory: plainConfiguration.workingDirectory
            )
            #expect(!plain.combinedPrompt.contains(Self.worktreeHeading))
            #expect(plain.systemPrompt.contains(workingDirectorySection))
        }
    }

    @Test
    func aSessionInAnotherFolderOfTheSameLaunchHasNoSection() async throws {
        try await withWorkspaces { workspace, other in
            let configuration = try AgentConfiguration.withoutPersistedConfiguration(
                arguments: ["zen", "--worktree", "feature", "--working-directory", workspace.path]
            )

            // An app window opened on another workspace shares the launch
            // environment but does not work in the worktree.
            let elsewhere = await Self.promptSections(
                configuration: configuration,
                workingDirectory: other
            )
            #expect(!elsewhere.combinedPrompt.contains(Self.worktreeHeading))

            // The worktree reached through an unresolved path (the temporary
            // folder is a symbolic link on macOS) is still the worktree.
            let unresolved = await Self.promptSections(
                configuration: configuration,
                workingDirectory: workspace
            )
            #expect(unresolved.systemPrompt.contains(Self.worktreeHeading))
        }
    }

    // MARK: - Support

    @ChatSessionActor
    private static func promptSections(
        configuration: AgentConfiguration,
        workingDirectory: URL
    ) -> SystemPromptSections {
        controller(configuration: configuration, workingDirectory: workingDirectory)
            .currentPromptSections(allowedToolNames: [], responseLanguageSection: nil)
    }

    @ChatSessionActor
    private static func sessionConfiguration(
        configuration: AgentConfiguration,
        workingDirectory: URL
    ) -> AgentCoreSessionConfiguration {
        controller(configuration: configuration, workingDirectory: workingDirectory)
            .currentSessionConfiguration(allowedToolNames: [], responseLanguageSection: nil)
    }

    @ChatSessionActor
    private static func controller(
        configuration: AgentConfiguration,
        workingDirectory: URL
    ) -> ChatSessionController {
        let host = ScriptedChatInteractionHost(capabilities: [.toolConsent])
        return ChatSessionController(
            sessionID: "worktree-prompt-\(UUID().uuidString.lowercased())",
            runtime: ScriptedChatRuntime(),
            environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
            workingDirectory: workingDirectory,
            presenter: RecordingChatPresenter(),
            host: host,
            authorizer: ChatToolConsentAuthorizer(host: host)
        )
    }

    /// Runs `body` with two temporary workspaces and a temporary support
    /// directory, all removed afterwards.
    private func withWorkspaces(
        _ body: @Sendable (_ workspace: URL, _ other: URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-worktree-prompt-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("feature/app", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        for directory in [support, workspace, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try await body(workspace, other)
        }
    }
}
