//
//  ZenCODEACPBridge+WorkspaceCommands.swift
//  ZenCODE
//
//  ACP answer to /changes and /undo: the file changes of the last turn, with
//  their patches on request, and their reversal.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// `/changes` and `/undo` in an ACP session, on the shared commands
/// (``ChatSessionController/runChangesCommand(line:)``,
/// ``ChatSessionController/runUndoCommand(line:)``), which read and revert the
/// summary the controller keeps for the last turn that changed files. They are
/// answered at once, before the coordinator parser, and never reach the model.
///
/// The terminal draws the patches of `/changes diff` with its own renderer, and
/// the shared text of the summary carries none, so ACP writes them: one block
/// per file, in a Markdown `diff` fence, built from the same bounded artifacts
/// the terminal shows (``FileChangeArtifactMapper``) and the neutral unified
/// diff (``FileChangeArtifactDiff``). Every other argument of `/changes` is
/// ignored and `/undo` refuses any, as the shared commands always did.
///
/// `/undo` is the only one of the two that changes something, so it respects
/// the command fence on both sides of the reversal: a prompt that no longer
/// holds the session never starts it, and one that lost the session while the
/// files were restored ends `cancelled` without presenting the answer. The
/// reversal itself runs in the controller and is not undone: the files stay
/// restored and the summary forgotten, as the controller leaves them.
extension ZenCODEACPBridge {
    static let changesCommandToken = "/changes"
    static let undoCommandToken = "/undo"

    /// Only an unambiguous user-facing text block can name a workspace
    /// command. Rendered resources and assistant-only context are not input
    /// from the operator. The known Xcode context prefix is the only accepted
    /// multi-text form, and only its final block may name a command.
    static func workspaceCommandSource(from blocks: [Any]) -> String? {
        var texts: [String] = []
        for block in blocks {
            if let text = block as? String {
                texts.append(text)
                continue
            }
            guard let object = block as? [String: Any],
                  (object["type"] as? String ?? "text").lowercased() == "text",
                  let text = object["text"] as? String else {
                continue
            }
            if let annotations = object["annotations"] as? [String: Any],
               let audience = annotations["audience"] as? [String],
               !audience.contains("user") {
                continue
            }
            texts.append(text)
        }
        let nonempty = texts.compactMap(\.nilIfBlank)
        guard let last = nonempty.last, nonempty.dropLast().allSatisfy({ prefix in
            (prefix.hasPrefix("<system-reminder>") && prefix.hasSuffix("</system-reminder>"))
                || prefix.hasPrefix("Project structure:")
        }) else { return nil }
        return last
    }

    /// Whether `line` names a workspace command ACP answers itself.
    static func isWorkspaceCommand(_ line: String) -> Bool {
        switch ChatCommandRegistry.commandToken(from: line) {
        case changesCommandToken, undoCommandToken:
            return true
        default:
            return false
        }
    }

    /// The answer to the `/changes` or `/undo` line `line` of the prompt that
    /// holds the reservation `promptID`.
    func routeACPWorkspaceCommand(
        _ line: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID,
        fence: ChatCommandFence
    ) async throws -> ACPCommandTurnRoute {
        guard let session = await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        let controller = session.controller
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUndo = ChatCommandRegistry.commandToken(from: trimmed) == Self.undoCommandToken

        let outcome = try await Self.performFenced(fence, on: controller) {
            isUndo
                ? await controller.runUndoCommand(line: trimmed)
                : await controller.runChangesCommand(line: trimmed)
        }
        return .immediate(Self.workspaceText(for: outcome, workingDirectory: controller.nonisolatedWorkingDirectory))
    }

    /// Runs `operation`, a shared workspace command, only while `fence` holds
    /// and reports the command cancelled when it was lost: before, so a prompt
    /// that no longer holds the session changes nothing, and after, so the
    /// answer of a command the session lost is never presented. The operation
    /// is not rolled back: the files `/undo` restored stay restored.
    static func performFenced(
        _ fence: ChatCommandFence,
        on controller: ChatSessionController,
        operation: () async -> ChatCommandOutcome
    ) async throws -> ChatCommandOutcome {
        guard controller.isCurrent(fence) else {
            throw CancellationError()
        }
        let outcome = await operation()
        guard controller.isCurrent(fence) else {
            throw CancellationError()
        }
        return outcome
    }

    /// The notices of a workspace command as one ACP message.
    static func workspaceText(
        for outcome: ChatCommandOutcome,
        workingDirectory: URL
    ) -> String {
        outcome.notices
            .map { notice -> String in
                let text = acpText(for: notice, context: .workspace)
                guard case let .fileChangeSummary(summary, includesDiff: true) = notice,
                      let patches = patchesMarkdown(for: summary, workingDirectory: workingDirectory) else {
                    return text
                }
                return text + "\n\n" + patches
            }
            .joined(separator: "\n")
    }

    /// The patches of `summary`, one section per file: its name, counts, and
    /// explanation, then the diff in a `diff` block. A binary file, and a file
    /// with no diff to show, keep the section without the block. `nil` for a
    /// summary without files.
    static func patchesMarkdown(
        for summary: TurnFileChangeSummary,
        workingDirectory: URL
    ) -> String? {
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: summary,
            workingDirectory: workingDirectory
        )
        let sections = artifacts.map { artifact -> String in
            var parts = [ChatSessionNoticeText.fileArtifactMetadata(artifact)]
            if let explanation = artifact.explanation?.nilIfBlank {
                parts.append("Explanation: \(explanation)")
            }
            if !artifact.isBinary,
               let diff = FileChangeArtifactDiff.unifiedDiff(
                   for: artifact,
                   scope: .changedLines(contextLines: 3)
               ) {
                parts.append(
                    FileChangeArtifactDiff.markdownCodeBlock(diff, language: "diff")
                        .joined(separator: "\n")
                )
            }
            return parts.joined(separator: "\n\n")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
