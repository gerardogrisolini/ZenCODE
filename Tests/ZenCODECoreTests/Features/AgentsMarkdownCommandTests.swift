//
//  AgentsMarkdownCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct AgentsMarkdownCommandTests {
    @Test
    func agentsMarkdownCommandIsVisibleAndDoesNotRequireAnArgument() throws {
        let descriptor = try #require(
            TerminalChat.visibleCommandDescriptors(
                builderAgentEnabled: false,
                telegramEnabled: false
            ).first(where: { $0.command == "/agents-md" })
        )

        #expect(!descriptor.requiresArgument)
        #expect(descriptor.help.contains("current working directory"))
        #expect(descriptor.help.contains("without assuming a project type"))
        #expect(descriptor.help.contains("new or updated workspace"))
        #expect(TerminalChat.isKnownSlashCommand("/agents-md"))
        #expect(!TerminalChat.isKnownSlashCommand("/agents-md-extra"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/agents-md"))
        #expect(
            TerminalChat.visibleCommandDescriptors(
                builderAgentEnabled: false,
                telegramEnabled: false
            ).allSatisfy { $0.command != "/make-agents" }
        )
    }

    @Test
    func legacyMakeAgentsNameStaysAcceptedAsAHiddenAlias() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let terminal = try makeTerminal(workingDirectory: workingDirectory)
        terminal.selectedToolKeys = ["files"]

        #expect(TerminalChat.isKnownSlashCommand("/make-agents"))
        #expect(!TerminalChat.isKnownSlashCommand("/make-agents-extra"))

        switch await terminal.submittedLineAction("/make-agents") {
        case let .runHiddenPrompt(prompt, purpose):
            #expect(purpose == .agentsMarkdown)
            #expect(prompt.contains("Create or update `AGENTS.md`"))
        default:
            Issue.record("/make-agents should still start the /agents-md prompt")
        }
    }

    @Test
    func generatedPromptTreatsTheWorkingDirectoryAsAnArbitraryWorkspace() {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/An arbitrary folder",
            isDirectory: true
        )

        let prompt = TerminalChat.agentsMarkdownPrompt(
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
    func agentsMarkdownPurposeRestrictsToolsAndExcludesWorkflowMutation() {
        let allowed = TerminalChat.agentsMarkdownAllowedToolNames

        #expect(allowed.contains("local.ls"))
        #expect(allowed.contains("local.readFile"))
        #expect(allowed.contains("local.writeFile"))
        #expect(!allowed.contains("local.exec"))
        #expect(!allowed.contains("local.editFile"))
        #expect(!allowed.contains("tasks.update"))
        #expect(!allowed.contains("agent.create"))
        #expect(!allowed.contains("memory.write"))
    }

    @Test
    func agentsMarkdownRunsAsAHiddenModelPromptWithoutWritingItself() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let terminal = try makeTerminal(workingDirectory: workingDirectory)
        terminal.selectedToolKeys = ["files"]

        let action = await terminal.submittedLineAction("/agents-md")

        switch action {
        case let .runHiddenPrompt(prompt, purpose):
            #expect(purpose == .agentsMarkdown)
            #expect(prompt.contains(workingDirectory.path))
            #expect(prompt.contains("Create or update `AGENTS.md`"))
        case .runPrompt:
            Issue.record("/agents-md should keep its generated instruction hidden")
        default:
            Issue.record("/agents-md should start a model-driven prompt")
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
    func agentsMarkdownRejectsArgumentsAndMissingFileTools() async throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let terminal = try makeTerminal(workingDirectory: workingDirectory)

        terminal.selectedToolKeys = ["files"]
        #expect(isContinueChat(
            await terminal.submittedLineAction("/agents-md somewhere-else")
        ))

        terminal.selectedToolKeys = []
        #expect(isContinueChat(
            await terminal.submittedLineAction("/agents-md")
        ))
    }

    @Test
    func writeOutcomeReportsAMissingFileWhenTheModelOnlyDraftsIt() throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let outcome = TerminalChat.agentsMarkdownWriteOutcome(
            workingDirectory: workingDirectory,
            fileChangeSummary: nil
        )

        #expect(outcome == .missing)
        let notice = try #require(TerminalChat.agentsMarkdownNotice(for: outcome))
        #expect(notice.contains("did not write AGENTS.md"))
    }

    @Test
    func writeOutcomeReportsAnUntouchedExistingFile() throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        try writeAgentsMarkdown(in: workingDirectory)

        let unrelatedChange = TurnFileChangeSummary(
            entries: [makeEntry(path: "notes/README.md")]
        )

        let outcome = TerminalChat.agentsMarkdownWriteOutcome(
            workingDirectory: workingDirectory,
            fileChangeSummary: unrelatedChange
        )

        #expect(outcome == .unchanged)
        let notice = try #require(TerminalChat.agentsMarkdownNotice(for: outcome))
        #expect(notice.contains("unchanged"))
    }

    @Test
    func writeOutcomeAcceptsRelativeAndAbsoluteChangePaths() throws {
        let workingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        try writeAgentsMarkdown(in: workingDirectory)

        let relativeOutcome = TerminalChat.agentsMarkdownWriteOutcome(
            workingDirectory: workingDirectory,
            fileChangeSummary: TurnFileChangeSummary(
                entries: [makeEntry(path: AgentsContextService.filename)]
            )
        )
        let absoluteOutcome = TerminalChat.agentsMarkdownWriteOutcome(
            workingDirectory: workingDirectory,
            fileChangeSummary: TurnFileChangeSummary(
                entries: [
                    makeEntry(
                        path: workingDirectory
                            .appendingPathComponent(AgentsContextService.filename)
                            .path
                    )
                ]
            )
        )

        #expect(relativeOutcome == .written)
        #expect(absoluteOutcome == .written)
        #expect(TerminalChat.agentsMarkdownNotice(for: .written) == nil)
    }

    private func makeTerminal(workingDirectory: URL) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
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
                "agents-md-command-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeAgentsMarkdown(in directory: URL) throws {
        try "# Workspace\n".write(
            to: directory.appendingPathComponent(AgentsContextService.filename),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeEntry(path: String) -> TurnFileChangeSummary.Entry {
        TurnFileChangeSummary.Entry(
            path: path,
            additions: 1,
            deletions: 0,
            status: .added,
            isBinary: false,
            existedBefore: false,
            beforeDataBase64: nil,
            patch: nil
        )
    }

    private func isContinueChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action {
            return true
        }
        return false
    }
}
