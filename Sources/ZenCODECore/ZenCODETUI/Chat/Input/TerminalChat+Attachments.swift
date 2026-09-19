//
//  TerminalChat+Attachments.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

struct TerminalAttachmentPickerEntry: Hashable, Sendable {
    enum Kind: String, Sendable {
        case directory
        case image
        case video
    }

    let path: String
    let title: String
    let kind: Kind
}

extension TerminalChat {
    public func handleAttachCommand(_ command: String) async throws {
        let rawArguments = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/attach"
        )

        let urls: [URL]
        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await writeSystemMessage(
                    "ZenCODE: /attach without a path requires an interactive terminal.\n"
                        + Self.renderAttachmentUsage()
                )
                return
            }

            guard let selectedURL = await selectAttachmentURLInteractively() else {
                await writeSystemMessage("Attachment selection cancelled.\n")
                return
            }
            urls = [selectedURL]
        } else {
            let paths = try Self.splitAttachmentCommandArguments(rawArguments)
            guard let first = paths.first else {
                await writeSystemMessage(Self.renderAttachmentUsage())
                return
            }

            switch first.lowercased() {
            case "list":
                await writePendingAttachments()
                return
            case "delete":
                let deleteArgument = paths.dropFirst().joined(separator: " ")
                try await deletePendingAttachments(argument: deleteArgument)
                return
            default:
                break
            }

            urls = paths.map { resolvedAttachmentURL(from: $0) }
        }

        let attachments = try AgentRuntimeAttachmentStore.importRuntimeAttachments(from: urls)
        pendingAttachments.append(contentsOf: attachments)

        let noun = attachments.count == 1 ? "attachment" : "attachments"
        await writeSystemMessage(
            "Added \(attachments.count) \(noun). \(pendingAttachments.count) pending.\n"
        )
        await writePendingAttachments()
    }

    public func deletePendingAttachments(argument: String) async throws {
        let rawArgument = argument.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !pendingAttachments.isEmpty else {
            await writeSystemMessage("No pending attachments.\n")
            return
        }

        guard !rawArgument.isEmpty else {
            await writeSystemMessage(Self.renderAttachmentDeleteUsage())
            return
        }

        if rawArgument.lowercased() == "all" {
            pendingAttachments.removeAll()
            await writeSystemMessage("Removed all pending attachments.\n")
            return
        }

        guard let index = Int(rawArgument), index > 0, index <= pendingAttachments.count else {
            throw TerminalAttachmentCommandError.invalidDetachArgument(rawArgument)
        }

        let removedAttachment = pendingAttachments.remove(at: index - 1)
        await writeSystemMessage(
            "Removed attachment: \(removedAttachment.originalFilename)\n"
        )
        await writePendingAttachments()
    }

    public func writePendingAttachments() async {
        guard !pendingAttachments.isEmpty else {
            await writeSystemMessage("No pending attachments.\n")
            return
        }

        let lines = pendingAttachments.enumerated().map { index, attachment in
            Self.renderAttachmentLine(number: index + 1, attachment: attachment)
        }
        await writeSystemMessage(
            """
            Pending attachments:
            \(lines.joined(separator: "\n"))
            Send a prompt to include them, or press return on an empty prompt.

            """
        )
    }

    public func consumePendingAttachmentsForPrompt() -> [AgentRuntimeAttachment] {
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        return attachments
    }

    public nonisolated static func renderAttachmentUsage() -> String {
        """
        Usage: /attach                    Open the terminal attachment picker
               /attach <image-or-video-file> [file ...]
               /attach list
               /attach delete [all|attachment-number]

        """
    }

    nonisolated static func attachmentPickerEntries(
        in directory: URL
    ) -> [TerminalAttachmentPickerEntry] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isHiddenKey,
                .localizedNameKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children.compactMap { child in
            let displayValues = try? child.resourceValues(
                forKeys: [.isHiddenKey, .localizedNameKey]
            )
            guard displayValues?.isHidden != true else {
                return nil
            }

            // URLResourceValues describes a symlink itself, not its target. Resolve
            // it before applying the directory/file rules so linked folders remain
            // navigable (for example, a Desktop/Documents redirect).
            let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
            let resourceValues = try? resolvedChild.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey]
            )
            let path = resolvedChild.path
            let title = displayValues?.localizedName?.nilIfBlank ?? child.lastPathComponent

            if resourceValues?.isDirectory == true {
                return TerminalAttachmentPickerEntry(
                    path: path,
                    title: title,
                    kind: .directory
                )
            }

            guard resourceValues?.isRegularFile == true,
                  let attachmentKind = try? AgentRuntimeAttachmentStore.attachmentKind(
                      for: resolvedChild
                  ) else {
                return nil
            }

            let kind: TerminalAttachmentPickerEntry.Kind
            switch attachmentKind {
            case .image:
                kind = .image
            case .video:
                kind = .video
            }
            return TerminalAttachmentPickerEntry(path: path, title: title, kind: kind)
        }
        .sorted { lhs, rhs in
            let lhsIsDirectory = lhs.kind == .directory
            let rhsIsDirectory = rhs.kind == .directory
            if lhsIsDirectory != rhsIsDirectory {
                return lhsIsDirectory
            }
            let normalizedLHS = lhs.title.lowercased()
            let normalizedRHS = rhs.title.lowercased()
            return normalizedLHS == normalizedRHS
                ? lhs.title < rhs.title
                : normalizedLHS < normalizedRHS
        }
    }

    nonisolated static func attachmentPickerCanReadDirectory(at directory: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: directory.path)
    }

    public nonisolated static func renderAttachmentDeleteUsage() -> String {
        "Usage: /attach delete [all|attachment-number]\n"
    }

    public nonisolated static func renderAttachmentLine(
        number: Int,
        attachment: AgentRuntimeAttachment
    ) -> String {
        var details = [
            attachment.kind.rawValue,
            attachment.contentType?.nilIfBlank
        ].compactMap { $0 }

        if let byteCount = AgentRuntimeAttachmentStore.byteCount(for: attachment) {
            details.append(Self.renderByteCount(byteCount))
        }

        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "  \(number). \(attachment.originalFilename)\(suffix)"
    }

    public nonisolated static func splitAttachmentCommandArguments(_ rawArguments: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaping = false

        for character in rawArguments {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

                        if character == "\\" {
                isEscaping = true
                continue
            }

            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                activeQuote = character
                continue
            }

            if character.isShellWhitespace {
                if !current.isEmpty {
                    arguments.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if isEscaping {
            current.append("\\")
        }
        if activeQuote != nil {
            throw TerminalAttachmentCommandError.unterminatedQuote
        }
        if !current.isEmpty {
            arguments.append(current)
        }
        return arguments
    }

    private func resolvedAttachmentURL(from rawPath: String) -> URL {
        Self.resolvedWorkspaceFileURL(
            from: rawPath,
            workingDirectory: configuration.workingDirectory,
            recognizingFileURLs: true
        )
    }

    private func selectAttachmentURLInteractively() async -> URL? {
        var directory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        while true {
            guard Self.attachmentPickerCanReadDirectory(at: directory) else {
                await writeSystemMessage(
                    "Unable to read attachment directory: \(directory.path).\n"
                        + "Grant ZenCODE access in System Settings > Privacy & Security > Files and Folders.\n"
                )
                return nil
            }

            let entries = Self.attachmentPickerEntries(in: directory)
            let parentDirectory = directory.deletingLastPathComponent().standardizedFileURL
            var items: [TerminalCheckboxMenuItem<String>] = []

            if directory.path != "/" {
                items.append(
                    TerminalCheckboxMenuItem(
                        value: parentDirectory.path,
                        title: "..",
                        detail: "parent directory"
                    )
                )
            }

            items.append(contentsOf: entries.map { entry in
                TerminalCheckboxMenuItem(
                    value: entry.path,
                    title: entry.kind == .directory ? "\(entry.title)/" : entry.title,
                    detail: entry.kind.rawValue
                )
            })

            guard !items.isEmpty else {
                await writeSystemMessage(
                    "No image or video files found in \(directory.path).\n"
                )
                return nil
            }

            guard let selectedPath = await TerminalCheckboxMenu.selectOneOffActor(
                title: "Attach image or video — \(directory.path)",
                items: items,
                selected: nil,
                reservedBottomRows: await statusBar.reservedRowsForOverlay()
            ) else {
                return nil
            }

            if selectedPath == parentDirectory.path, directory.path != "/" {
                directory = parentDirectory
                continue
            }

            guard let selectedEntry = entries.first(where: { $0.path == selectedPath }) else {
                continue
            }
            if selectedEntry.kind == .directory {
                directory = URL(fileURLWithPath: selectedEntry.path).standardizedFileURL
                continue
            }
            return URL(fileURLWithPath: selectedEntry.path).standardizedFileURL
        }
    }

    private nonisolated static func renderByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(byteCount),
            countStyle: .file
        )
    }
}

private enum TerminalAttachmentCommandError: LocalizedError {
    case invalidDetachArgument(String)
    case unterminatedQuote

    var errorDescription: String? {
        switch self {
        case let .invalidDetachArgument(argument):
            return "Invalid attachment selection: \(argument)."
        case .unterminatedQuote:
            return "Unterminated quoted attachment path."
        }
    }
}

private extension Character {
    var isShellWhitespace: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
