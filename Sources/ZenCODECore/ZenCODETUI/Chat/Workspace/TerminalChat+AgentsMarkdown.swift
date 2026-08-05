//
//  TerminalChat+AgentsMarkdown.swift
//  ZenCODE
//

import Foundation

/// Result of checking whether the `/agents-md` turn actually produced the file
/// it was asked to write. The command delegates authoring to the model, so the
/// post-condition is verified against tracked file changes instead of trusting
/// the response text.
enum AgentsMarkdownWriteOutcome: Sendable, Equatable {
    /// `AGENTS.md` exists and was created or modified during the turn.
    case written
    /// `AGENTS.md` is absent after the turn.
    case missing
    /// `AGENTS.md` exists but the turn recorded no change to it.
    case unchanged
}

extension TerminalChat {
    nonisolated static let agentsMarkdownCommand = "/agents-md"

    /// Previous name of ``agentsMarkdownCommand``, still accepted so existing
    /// habits and documentation keep working.
    nonisolated static let agentsMarkdownLegacyCommand = "/make-agents"

    func handleAgentsMarkdownCommand(
        _ command: String
    ) async -> TerminalSubmittedLineAction {
        let commandPrefix = Self.commandToken(from: command)
            ?? Self.agentsMarkdownCommand
        if commandPrefix == Self.agentsMarkdownLegacyCommand {
            await writeSystemMessage(
                "ZenCODE: \(Self.agentsMarkdownLegacyCommand) is now \(Self.agentsMarkdownCommand).\n"
            )
        }
        let argument = Self.slashCommandArguments(
            from: command,
            commandPrefix: commandPrefix
        )
        guard argument.isEmpty else {
            await writeFailureMessage(
                "ZenCODE: \(Self.agentsMarkdownCommand) does not accept arguments; it updates AGENTS.md in the current working directory.\n"
            )
            return .continueChat
        }

        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        guard Self.agentsMarkdownRequiredToolNames.isSubset(of: allowedToolNames) else {
            await writeFailureMessage(
                "ZenCODE: \(Self.agentsMarkdownCommand) requires the Files tool group. Enable it with /tools (or switch to an agent that includes it) and try again.\n"
            )
            return .continueChat
        }

        await writeSubmittedPrompt(command)
        return .runHiddenPrompt(
            Self.agentsMarkdownPrompt(
                workingDirectory: configuration.workingDirectory
            ),
            purpose: .agentsMarkdown
        )
    }

    nonisolated static func agentsMarkdownPrompt(workingDirectory: URL) -> String {
        let directoryLiteral = jsonStringLiteral(
            workingDirectory.standardizedFileURL.path
        )
        return """
        Create or update `AGENTS.md` for the current working directory.

        Target directory (JSON string): \(directoryLiteral)
        Target filename: "AGENTS.md"

        Treat the target directory as an arbitrary workspace. It may be empty, may contain documents or other non-code material, and may or may not be a source-code repository. Do not assume any project type, programming language, build system, toolchain, directory layout, or version-control system.

        Handle this as one focused maintenance turn. Do not delegate it, create or update a task graph, or advance an unrelated active plan.

        Requirements:
        1. Inspect the target directory with the available read, list, and search tools before deciding what belongs in the file. Keep inspection focused and do not modify anything during discovery.
        2. If `AGENTS.md` already exists in the target directory, read it first and update it conservatively. Preserve useful user-authored guidance unless current workspace evidence shows that it is obsolete or incorrect.
        3. Include only durable, actionable guidance supported by what you actually observe, such as the workspace purpose, important structure, authoritative files, confirmed workflows or commands, constraints, and non-obvious validation steps. Omit categories for which there is no evidence; if there is no durable guidance to record, keep the file minimal rather than inventing content.
        4. Do not invent facts, commands, paths, conventions, or requirements. Do not emit a predefined template, generic inventory, placeholders, secrets, absolute machine-specific paths, or rules already supplied by the system prompt.
        5. Create or update exactly `AGENTS.md` in the target directory using an available file mutation tool. Do not modify any other file and do not merely propose or print a draft in the response.
        6. Re-read the completed file, check every claim against the inspected workspace, and keep it concise. Then summarize what you changed and note any important limitation caused by missing evidence.
        """
    }

    /// Verifies the post-condition of an `/agents-md` turn. The turn "succeeds"
    /// only when `AGENTS.md` exists in the working directory *and* the turn
    /// recorded a change to it, so a response that merely prints a draft is
    /// reported instead of passing silently.
    nonisolated static func agentsMarkdownWriteOutcome(
        workingDirectory: URL,
        fileChangeSummary: TurnFileChangeSummary?,
        fileManager: FileManager = .default
    ) -> AgentsMarkdownWriteOutcome {
        let fileURL = agentsMarkdownFileURL(workingDirectory: workingDirectory)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
        guard exists else {
            return .missing
        }

        let didChange = fileChangeSummary?.entries.contains { entry in
            isAgentsMarkdownPath(entry.path, workingDirectory: workingDirectory)
        } ?? false
        return didChange ? .written : .unchanged
    }

    nonisolated static func agentsMarkdownNotice(
        for outcome: AgentsMarkdownWriteOutcome
    ) -> String? {
        switch outcome {
        case .written:
            return nil
        case .missing:
            return "ZenCODE: \(Self.agentsMarkdownCommand) did not write \(AgentsContextService.filename); the model reported without creating it. Review the response and run \(Self.agentsMarkdownCommand) again.\n"
        case .unchanged:
            return "ZenCODE: \(Self.agentsMarkdownCommand) left the existing \(AgentsContextService.filename) unchanged.\n"
        }
    }

    func writeAgentsMarkdownOutcomeIfNeeded(
        _ outcome: AgentsMarkdownWriteOutcome
    ) async {
        guard let notice = Self.agentsMarkdownNotice(for: outcome) else {
            return
        }
        switch outcome {
        case .missing:
            await writeFailureMessage(notice)
        case .unchanged, .written:
            await writeSystemMessage(notice)
        }
    }

    nonisolated static let agentsMarkdownAllowedToolNames: Set<String> = [
        "git.diff",
        "git.grep",
        "git.log",
        "git.lsFiles",
        "git.show",
        "git.status",
        "local.inspectFile",
        "local.ls",
        "local.pwd",
        "local.readFile",
        "local.readFiles",
        "local.writeFile",
        "search.glob",
        "search.grep",
        "search.locate",
        "text.head",
        "text.tail",
        "text.wc",
    ]

    private nonisolated static let agentsMarkdownRequiredToolNames: Set<String> = [
        "local.ls",
        "local.readFile",
        "local.writeFile",
    ]

    private nonisolated static func agentsMarkdownFileURL(
        workingDirectory: URL
    ) -> URL {
        workingDirectory
            .appendingPathComponent(AgentsContextService.filename)
            .standardizedFileURL
    }

    /// File-change entries use a workspace-relative display path when the file
    /// lives inside the working directory and an absolute path otherwise.
    private nonisolated static func isAgentsMarkdownPath(
        _ path: String,
        workingDirectory: URL
    ) -> Bool {
        guard !path.isEmpty else {
            return false
        }
        let resolvedURL = URL(
            fileURLWithPath: path,
            relativeTo: workingDirectory.standardizedFileURL
        ).standardizedFileURL
        return resolvedURL.path == agentsMarkdownFileURL(
            workingDirectory: workingDirectory
        ).path
    }

    private nonisolated static func jsonStringLiteral(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let literal = String(validating: data, as: UTF8.self) else {
            return "\"\""
        }
        return literal
    }
}
