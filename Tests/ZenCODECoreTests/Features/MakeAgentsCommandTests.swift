//
//  MakeAgentsCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct MakeAgentsCommandTests {
    @Test
    func makeAgentsCommandIsVisibleAndDoesNotRequireAnArgument() throws {
        let descriptor = try #require(
            TerminalChat.visibleCommandDescriptors(
                builderAgentEnabled: false,
                telegramEnabled: false,
                voiceEnabled: false
            ).first(where: { $0.command == "/make-agents" })
        )

        #expect(!descriptor.requiresArgument)
        #expect(descriptor.help.contains("current working directory"))
        #expect(descriptor.help.contains("without assuming a project type"))
        #expect(TerminalChat.isKnownSlashCommand("/make-agents"))
        #expect(!TerminalChat.isKnownSlashCommand("/make-agents-extra"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/make-agents"))
    }

    @Test
    func generatedPromptTreatsTheWorkingDirectoryAsAnArbitraryWorkspace() {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/An arbitrary folder",
            isDirectory: true
        )

        let prompt = TerminalChat.makeAgentsPrompt(
            workingDirectory: workingDirectory
        )

        #expect(prompt.contains("/tmp/An arbitrary folder"))
        #expect(prompt.contains("arbitrary workspace"))
        #expect(prompt.contains("may not be a source-code repository"))
        #expect(prompt.contains("read it first"))
        #expect(prompt.contains("Preserve useful user-authored guidance"))
        #expect(prompt.contains("Do not invent facts, commands, paths"))
        #expect(prompt.contains("Do not delegate it"))
        #expect(prompt.contains("Do not modify any other file"))
        #expect(prompt.contains("do not merely propose or print a draft"))
        #expect(!prompt.contains("Package.swift"))
        #expect(!prompt.contains("swift build"))
        #expect(!prompt.contains("Xcode"))
        #expect(!prompt.contains("Sources/"))
        #expect(!prompt.contains("Tests/"))
    }

    @Test
    func makeAgentsPurposeRestrictsToolsAndExcludesWorkflowMutation() {
        let allowed = TerminalChat.makeAgentsAllowedToolNames

        #expect(allowed.contains("local.ls"))
        #expect(allowed.contains("local.readFile"))
        #expect(allowed.contains("local.writeFile"))
        #expect(!allowed.contains("local.exec"))
        #expect(!allowed.contains("local.editFile"))
        #expect(!allowed.contains("task.update"))
        #expect(!allowed.contains("agent.create"))
        #expect(!allowed.contains("memory.write"))
    }

    @Test
    func makeAgentsRunsAsAHiddenModelPromptWithoutWritingItself() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let terminal = try makeTerminal(workingDirectory: workingDirectory)
        terminal.selectedToolKeys = ["files"]

        let action = await terminal.submittedLineAction("/make-agents")

        switch action {
        case let .runHiddenPrompt(prompt, purpose):
            #expect(purpose == .makeAgents)
            #expect(prompt.contains(workingDirectory.path))
            #expect(prompt.contains("Create or update `AGENTS.md`"))
        case .runPrompt:
            Issue.record("/make-agents should keep its generated instruction hidden")
        default:
            Issue.record("/make-agents should start a model-driven prompt")
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: workingDirectory
                    .appendingPathComponent(AgentsContextService.filename)
                    .path
            )
        )
    }

    @Test
    func makeAgentsRejectsArgumentsAndMissingFileTools() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let terminal = try makeTerminal(workingDirectory: workingDirectory)

        terminal.selectedToolKeys = ["files"]
        #expect(isContinueChat(
            await terminal.submittedLineAction("/make-agents somewhere-else")
        ))

        terminal.selectedToolKeys = []
        #expect(isContinueChat(
            await terminal.submittedLineAction("/make-agents")
        ))
    }

    private func makeTerminal(workingDirectory: URL) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "make-agents-command-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func isContinueChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action {
            return true
        }
        return false
    }
}
