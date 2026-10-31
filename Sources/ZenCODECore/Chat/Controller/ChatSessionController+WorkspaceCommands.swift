//
//  ChatSessionController+WorkspaceCommands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The workspace commands shared by every channel: `/changes`, `/undo`, and
/// `/artifacts` over the session's file changes, `/open` for the files and
/// URLs the conversation mentions, and `/attach` with the attachments staged
/// for the next prompt.
///
/// None of them echoes the submitted line or starts a turn: everything they
/// say is in the outcome's notices. They refuse arguments as the terminal
/// always did: `/undo` takes none and answers as for an unknown command,
/// `/artifacts` takes none, and `/changes` reads only `diff` or `--diff`.
///
/// What needs the operator goes through the host and its capabilities: the
/// `/open` menu needs ``ChatChannelCapabilities/singleChoice``, opening a file
/// or URL ``ChatChannelCapabilities/externalOpen``, and the attachment picker
/// ``ChatChannelCapabilities/attachmentPicker`` with the home folder of the
/// ``ChatSessionEnvironment``. Without them the command answers with the
/// non-interactive output of the terminal.
extension ChatSessionController {
    // MARK: - /changes

    /// `/changes`: the summary of the last turn that changed files, with the
    /// patches for `/changes diff` or `/changes --diff`. Any other argument is
    /// ignored.
    func runChangesCommand(line: String) async -> ChatCommandOutcome {
        let arguments = ChatCommandRegistry.arguments(
            from: line,
            commandPrefix: "/changes"
        ).lowercased()
        let includesDiff = arguments == "diff" || arguments == "--diff"

        guard let summary = lastFileChangeSummary else {
            return ChatCommandOutcome(notices: [.noTrackedFileChanges])
        }
        return ChatCommandOutcome(notices: [.fileChangeSummary(summary, includesDiff: includesDiff)])
    }

    // MARK: - /undo

    /// `/undo`: restores the files of the last summary in the working
    /// directory and forgets the summary. A line with arguments names no
    /// command.
    func runUndoCommand(line: String) async -> ChatCommandOutcome {
        guard ChatCommandRegistry.arguments(from: line, commandPrefix: "/undo").isEmpty else {
            return ChatCommandOutcome(notices: [.unknownCommand(line: line)])
        }
        do {
            try await TurnFileChangeUndoService.undoLatest(
                summary: lastFileChangeSummary,
                baseDirectoryURL: workingDirectory
            )
            lastFileChangeSummary = nil
            return ChatCommandOutcome(notices: [.fileChangesReverted])
        } catch let error as TurnFileChangeUndoError {
            return ChatCommandOutcome(
                notices: [.fileChangesNotUndone(description: error.localizedDescription)]
            )
        } catch {
            return ChatCommandOutcome(
                notices: [.fileChangesUndoFailed(description: error.localizedDescription)]
            )
        }
    }

    // MARK: - /artifacts

    /// `/artifacts`: the file artifacts of every turn of the session. It
    /// accepts no arguments.
    func runArtifactsCommand(line: String) async -> ChatCommandOutcome {
        guard ChatCommandRegistry.arguments(from: line, commandPrefix: "/artifacts").isEmpty else {
            return ChatCommandOutcome(notices: [.artifactsTakeNoArguments])
        }
        let turns = await fileArtifactHistory.snapshot()
        guard !turns.isEmpty else {
            return ChatCommandOutcome(notices: [.noFileArtifacts])
        }
        return ChatCommandOutcome(notices: [.fileArtifacts(turns)])
    }

    // MARK: - /open

    /// `/open <file-or-url>` opens its argument directly; `/open` alone offers
    /// the files and URLs of the conversation (``openCandidates()``) in a menu,
    /// or lists them when the host has no menu.
    func runOpenCommand(line: String) async -> ChatCommandOutcome {
        let argument = ChatCommandRegistry.arguments(from: line, commandPrefix: "/open")
        if !argument.isEmpty {
            return ChatCommandOutcome(notices: await openDirectArgument(argument))
        }

        let candidates = openCandidates()
        guard !candidates.isEmpty else {
            return ChatCommandOutcome(notices: [.noOpenCandidates])
        }

        guard host.capabilities.contains(.singleChoice) else {
            return ChatCommandOutcome(
                notices: [.requiresInteractiveHost(.openSelection(candidates: candidates))]
            )
        }

        let items = candidates.enumerated().map { index, candidate in
            ChatChoiceItem(
                id: String(index),
                title: candidate.display,
                detail: candidate.kind == .url ? "url" : "file"
            )
        }
        guard let selectedID = await host.chooseOne(
            title: "Open file or URL",
            items: items,
            selectedID: items.first?.id
        ),
            let selectedIndex = Int(selectedID),
            candidates.indices.contains(selectedIndex) else {
            return ChatCommandOutcome(notices: [.nothingOpened])
        }

        return ChatCommandOutcome(notices: await open(candidates[selectedIndex].openTarget))
    }

    /// A URL of a known scheme is opened as it is; anything else is a path
    /// (``resolvedWorkspaceFileURL(from:recognizingFileURLs:)``) that must
    /// exist.
    private func openDirectArgument(_ argument: String) async -> [ChatSessionNotice] {
        if Self.urlCandidate(from: argument) != nil {
            return await open(ChatOpenTarget(target: argument, kind: .url))
        }

        let resolved = resolvedWorkspaceFileURL(from: argument)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return [.openTargetNotFound(argument: argument)]
        }
        return await open(ChatOpenTarget(target: resolved.path, kind: .file))
    }

    /// Asks the host to open `target`. A host without
    /// ``ChatChannelCapabilities/externalOpen`` is never asked: the answer is
    /// the refusal of ``ChatOpenExternalUnsupportedError``, for the direct
    /// form and the menu alike.
    private func open(_ target: ChatOpenTarget) async -> [ChatSessionNotice] {
        guard host.capabilities.contains(.externalOpen) else {
            return [.operationFailed(
                description: ChatOpenExternalUnsupportedError().localizedDescription
            )]
        }
        do {
            try await host.openExternal(target)
            return [.opening(target)]
        } catch {
            return [.operationFailed(description: error.localizedDescription)]
        }
    }

    // MARK: - /attach

    /// `/attach`: the picker without arguments, `list`, `delete`, or the
    /// image and video files the arguments name, which are staged in
    /// ``pendingAttachments`` for the next prompt.
    func runAttachCommand(line: String) async -> ChatCommandOutcome {
        let rawArguments = ChatCommandRegistry.arguments(from: line, commandPrefix: "/attach")

        let urls: [URL]
        if rawArguments.isEmpty {
            guard host.capabilities.contains(.attachmentPicker),
                  let homeDirectory = environment.userHomeDirectoryURL else {
                return ChatCommandOutcome(
                    notices: [.requiresInteractiveHost(.attachmentSelection)]
                )
            }
            guard let selectedURL = await host.pickAttachment(
                startingAt: homeDirectory.standardizedFileURL
            ) else {
                return ChatCommandOutcome(notices: [.attachmentSelectionCancelled])
            }
            urls = [selectedURL]
        } else {
            do {
                let paths = try Self.splitAttachmentCommandArguments(rawArguments)
                guard let first = paths.first else {
                    return ChatCommandOutcome(notices: [.attachmentUsage])
                }

                switch first.lowercased() {
                case "list":
                    return ChatCommandOutcome(notices: [.pendingAttachments(pendingAttachments)])
                case "delete":
                    let deleteArgument = paths.dropFirst().joined(separator: " ")
                    return ChatCommandOutcome(
                        notices: try deletePendingAttachments(argument: deleteArgument)
                    )
                default:
                    break
                }

                urls = paths.map { resolvedWorkspaceFileURL(from: $0, recognizingFileURLs: true) }
            } catch let error as ChatAttachmentCommandError {
                return ChatCommandOutcome(notices: [error.notice])
            } catch {
                return ChatCommandOutcome(
                    notices: [.operationFailed(description: error.localizedDescription)]
                )
            }
        }

        do {
            let attachments = try AgentRuntimeAttachmentStore.importRuntimeAttachments(from: urls)
            pendingAttachments.append(contentsOf: attachments)
            return ChatCommandOutcome(notices: [
                .attachmentsAdded(
                    addedCount: attachments.count,
                    pendingCount: pendingAttachments.count
                ),
                .pendingAttachments(pendingAttachments),
            ])
        } catch {
            return ChatCommandOutcome(
                notices: [.operationFailed(description: error.localizedDescription)]
            )
        }
    }

    /// `/attach delete [all|number]`: removes every staged attachment or the
    /// one with that number. Throws
    /// ``ChatAttachmentCommandError/invalidDetachArgument(_:)`` when
    /// `argument` names no staged attachment.
    func deletePendingAttachments(argument: String) throws -> [ChatSessionNotice] {
        let rawArgument = argument.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !pendingAttachments.isEmpty else {
            return [.noPendingAttachments]
        }

        guard !rawArgument.isEmpty else {
            return [.attachmentDeleteUsage]
        }

        if rawArgument.lowercased() == "all" {
            pendingAttachments.removeAll()
            return [.pendingAttachmentsRemoved]
        }

        guard let index = Int(rawArgument), index > 0, index <= pendingAttachments.count else {
            throw ChatAttachmentCommandError.invalidDetachArgument(rawArgument)
        }

        let removedAttachment = pendingAttachments.remove(at: index - 1)
        return [
            .attachmentRemoved(filename: removedAttachment.originalFilename),
            .pendingAttachments(pendingAttachments),
        ]
    }

    /// Hands the staged attachments to the prompt the operator sends and
    /// clears them.
    func consumePendingAttachments() -> [AgentRuntimeAttachment] {
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        return attachments
    }
}
