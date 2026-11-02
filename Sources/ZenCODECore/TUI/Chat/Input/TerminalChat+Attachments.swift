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
    /// `/attach`, run by the shared controller (see
    /// ``ChatSessionController/runAttachCommand(line:)``). The controller
    /// reports its failures as notices, so this adapter does not throw.
    public func handleAttachCommand(_ command: String) async throws {
        await writeSessionNotices(await chatSession.runAttachCommand(line: command).notices)
    }

    /// `/attach delete`: see ``ChatSessionController/deletePendingAttachments(argument:)``,
    /// whose ``ChatAttachmentCommandError`` this rethrows.
    public func deletePendingAttachments(argument: String) async throws {
        await writeSessionNotices(try chatSession.deletePendingAttachments(argument: argument))
    }

    /// `/attach list`: the attachments staged for the next prompt.
    public func writePendingAttachments() async {
        await writeSessionNotice(.pendingAttachments(pendingAttachments))
    }

    /// See ``ChatSessionController/consumePendingAttachments()``.
    public func consumePendingAttachmentsForPrompt() -> [AgentRuntimeAttachment] {
        chatSession.consumePendingAttachments()
    }

    /// See ``ChatSessionNoticeText/attachmentUsage``.
    public nonisolated static func renderAttachmentUsage() -> String {
        ChatSessionNoticeText.attachmentUsage
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

    /// See ``ChatSessionNoticeText/attachmentDeleteUsage``.
    public nonisolated static func renderAttachmentDeleteUsage() -> String {
        ChatSessionNoticeText.attachmentDeleteUsage
    }

    /// See ``ChatSessionNoticeText/attachmentLine(number:attachment:)``.
    public nonisolated static func renderAttachmentLine(
        number: Int,
        attachment: AgentRuntimeAttachment
    ) -> String {
        ChatSessionNoticeText.attachmentLine(number: number, attachment: attachment)
    }

    /// See ``ChatSessionController/splitAttachmentCommandArguments(_:)``,
    /// whose ``ChatAttachmentCommandError`` this rethrows.
    public nonisolated static func splitAttachmentCommandArguments(_ rawArguments: String) throws -> [String] {
        try ChatSessionController.splitAttachmentCommandArguments(rawArguments)
    }

    /// The terminal attachment picker behind
    /// ``TerminalInteractionHost/pickAttachment(startingAt:)``: it browses
    /// from `startingDirectory` and returns the chosen image or video file,
    /// or `nil` when the operator cancelled or the folder cannot be shown
    /// (after saying why).
    func selectAttachmentURLInteractively(startingAt startingDirectory: URL) async -> URL? {
        var directory = startingDirectory.standardizedFileURL

        while true {
            guard Self.attachmentPickerCanReadDirectory(at: directory) else {
                await writeSessionNotice(.attachmentDirectoryUnreadable(path: directory.path))
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
                await writeSessionNotice(.noAttachableFiles(directoryPath: directory.path))
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
}
