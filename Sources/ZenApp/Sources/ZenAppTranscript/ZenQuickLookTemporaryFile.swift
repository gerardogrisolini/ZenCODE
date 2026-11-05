//
//  ZenQuickLookTemporaryFile.swift
//  ZenApp
//
//  The private temporary copy of an attachment that has no file of its own, so
//  that Quick Look can show it: a file in a directory only the user can read,
//  removed when Quick Look closes.
//

import Foundation
import ZenCODECore

/// The private temporary file Quick Look shows for an attachment that has
/// only bytes: written in a directory of its own (permissions 0700) that is
/// removed when Quick Look closes.
enum ZenQuickLookTemporaryFile {
    // MARK: - Rules

    /// The start of the name of the directory that holds a temporary file;
    /// only a directory with it is ever removed.
    static let directoryPrefix = "ZenCODE-QuickLook-"

    /// The name of the temporary file of `attachment`: the last component of
    /// its original name, with `/` and `:` replaced by `-`, without the
    /// surrounding whitespace, or `attachment` when nothing is left. Quick Look
    /// chooses its viewer by the extension, so a name without one gets the
    /// extension of the content type of the attachment, when it has one.
    static func filename(for attachment: AgentRuntimeAttachment) -> String {
        let component = (attachment.originalFilename as NSString).lastPathComponent
        var name = component
            .replacing("/", with: "-")
            .replacing(":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = "attachment"
        }
        if (name as NSString).pathExtension.isEmpty {
            let fileExtension = AgentRuntimeAttachmentStore.preferredFilenameExtension(
                originalFilename: name,
                contentType: attachment.contentType
            )
            if !fileExtension.isEmpty {
                name += ".\(fileExtension)"
            }
        }
        return name
    }

    // MARK: - Files

    /// Writes `data` to the file `filename` in a new directory under `root`
    /// (permissions 0700), whose name starts with `directoryPrefix`; the file
    /// is created with permissions 0600, so it is never readable by others.
    /// Returns the URL of the file.
    /// - Throws: when `filename` is not a plain file name, or the directory or
    ///   the file cannot be created; the directory is not left behind.
    static func write(
        _ data: Data,
        filename: String,
        under root: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fileManager = FileManager.default
        let directory = root.appending(
            path: "\(directoryPrefix)\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appending(path: filename, directoryHint: .notDirectory)
        guard fileManager.createFile(
            atPath: file.path(percentEncoded: false),
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? fileManager.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    /// Removes the directory of the temporary file `fileURL`, with the file.
    /// Does nothing when the directory name does not start with
    /// `directoryPrefix`, so that no other file is ever removed. Errors are
    /// ignored.
    static func remove(_ fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix(directoryPrefix) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
