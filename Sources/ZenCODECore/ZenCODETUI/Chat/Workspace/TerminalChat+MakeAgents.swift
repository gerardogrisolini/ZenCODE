//
//  TerminalChat+MakeAgents.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    func handleMakeAgentsCommand(
        _ command: String
    ) async -> TerminalSubmittedLineAction {
        let argument = String(command.dropFirst("/make-agents".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard argument.isEmpty else {
            await writeFailureMessage(
                "ZenCODE: /make-agents does not accept arguments; it updates AGENTS.md in the current working directory.\n"
            )
            return .continueChat
        }

        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        guard Self.makeAgentsRequiredToolNames.isSubset(of: allowedToolNames) else {
            await writeFailureMessage(
                "ZenCODE: /make-agents requires the Files tool group. Enable it with /tools (or switch to an agent that includes it) and try again.\n"
            )
            return .continueChat
        }

        await writeSubmittedPrompt(command)
        return .runHiddenPrompt(
            Self.makeAgentsPrompt(
                workingDirectory: configuration.workingDirectory
            ),
            purpose: .makeAgents
        )
    }

    static func makeAgentsPrompt(workingDirectory: URL) -> String {
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

    static let makeAgentsAllowedToolNames: Set<String> = [
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

    private static let makeAgentsRequiredToolNames: Set<String> = [
        "local.ls",
        "local.readFile",
        "local.writeFile",
    ]

    private static func jsonStringLiteral(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
