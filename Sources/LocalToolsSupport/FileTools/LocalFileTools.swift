//
//  LocalToolsSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FeatureKit
import ToolCore


private func replacingAll(
    _ contents: String,
    oldText: String,
    with newText: String,
    notFoundMessage: @autoclosure () -> String
) throws -> (contents: String, replacements: Int) {
    let occurrences = contents.ranges(of: oldText).count
    guard occurrences > 0 else {
        throw LocalToolsFeatureError.permissionDenied(notFoundMessage())
    }
    return (
        contents.replacingOccurrences(of: oldText, with: newText),
        occurrences
    )
}

private func editFailureMessage(_ failure: LocalFileEditFailure, path: String) -> String {
    switch failure {
    case .emptyOld:
        "Edit failed in \(path): old text must not be empty."
    case .notFound:
        "Edit failed in \(path): old text was not found. Re-read the target range and retry with exact text."
    case let .ambiguous(count):
        "Edit failed in \(path): old text matched \(count) times. Include more surrounding context to make it unique."
    }
}

private func multiEditFailureMessage(
    _ failure: LocalFileEditFailure,
    edit: Int,
    total: Int,
    path: String
) -> String {
    let reason: String
    switch failure {
    case .emptyOld:
        reason = "old text must not be empty."
    case .notFound:
        reason = "old text was not found. Re-read the target range and retry with exact text."
    case let .ambiguous(count):
        reason = "old text matched \(count) times. Include more surrounding context to make it unique."
    }
    return "Multi-edit failed at edit \(edit) of \(total) in \(path): \(reason) No changes were written."
}


struct LocalPwdTool: FeatureTool {
    struct Input: Decodable, Sendable {}

    static let name = "local.pwd"
    static let description = "Returns the current working directory used by local tools."
    static let inputSchema = buildInputSchema([])

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        context.workingDirectory.path
    }
}

struct LocalListDirectoryTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let includeHidden: Bool?
    }

    static let name = "local.ls"
    static let description = "Lists files and directories. Paths may be absolute or relative to the working directory."
    static let inputSchema = buildInputSchema(
        [.string("path"), .boolean("includeHidden")],
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let url = try LocalToolsSupport.requiredPath(input.path, context: context)
        let includeHidden = input.includeHidden ?? false
        return try await LocalIOOffloader.run {
            try LocalToolsSupport.listDirectory(url, includeHidden: includeHidden)
        }
    }
}

struct LocalReadFileTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let offset: Int?
        let limit: Int?
    }

    static let name = "local.readFile"
    static let description = "Reads a UTF-8 text file with line numbers. Use offset and limit for focused reads."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases + CommonSchemaProperties.offsetLimit,
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let url = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let offset = input.offset
        let limit = input.limit
        return try await LocalIOOffloader.run {
            try LocalToolsSupport.readFile(url, offset: offset, limit: limit)
        }
    }
}

struct LocalReadFilesTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let paths: [String]?
        let file_paths: [String]?
        let offset: Int?
        let limit: Int?
    }

    static let name = "local.readFiles"
    static let description = "Reads multiple UTF-8 text files in one call. Each file is returned with a header and line numbers. Use offset and limit for focused reads applied to every file."
    static let inputSchema = buildInputSchema(
        [.array("paths"), .array("file_paths")] + CommonSchemaProperties.offsetLimit,
        required: ["paths"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let rawPaths = (input.paths ?? input.file_paths ?? [])
            .compactMap { $0.nilIfBlank }
        guard !rawPaths.isEmpty else {
            throw LocalToolsFeatureError.missingArgument("paths")
        }
        let offset = input.offset
        let limit = input.limit
        var sections: [String] = []
        for rawPath in rawPaths {
            // Honor cancellation between files so a multi-file read can be
            // aborted before touching remaining files.
            try Task.checkCancellation()
            let url = context.resolvePath(rawPath)
            do {
                let body = try await LocalIOOffloader.run {
                    try LocalToolsSupport.readFile(url, offset: offset, limit: limit)
                }
                sections.append("===== \(url.path) =====\n\(body)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sections.append("===== \(url.path) =====\n<error: \(error.localizedDescription)>")
            }
        }
        return sections.joined(separator: "\n\n")
    }
}

struct LocalInspectFileTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let maxSymbols: Int?
        let max_symbols: Int?
    }

    static let name = "local.inspectFile"
    static let description = "Returns compact file metadata, suggested read ranges, and symbol-like outline entries without returning the full file contents."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases + CommonSchemaProperties.symbolLimit,
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let url = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let maxSymbols = input.maxSymbols ?? input.max_symbols
        return try await LocalIOOffloader.run {
            try LocalToolsSupport.inspectFile(url, maxSymbols: maxSymbols)
        }
    }
}

struct LocalWriteFileTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let content: String?
        let createDirectories: Bool?
    }

    static let name = "local.writeFile"
    static let description = "Creates or overwrites a UTF-8 text file."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases + [.string("content"), .boolean("createDirectories")],
        required: ["path", "content"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        guard let content = input.content else {
            throw LocalToolsFeatureError.missingArgument("content")
        }
        let createDirectories = input.createDirectories == true
        let byteCount = content.utf8.count
        return try await LocalIOOffloader.run {
            if createDirectories {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            try content.write(to: path, atomically: true, encoding: .utf8)
            return "Wrote \(path.path) (\(byteCount) bytes)."
        }
    }
}

struct LocalReplaceTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let old: String?
        let new: String?
    }

    static let name = "local.replace"
    static let description = "Replaces all occurrences of `old` with `new` in a UTF-8 text file."
    static let inputSchema = buildInputSchema(
        [.string("path")] + CommonSchemaProperties.edit,
        required: ["path", "old", "new"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, context: context)
        let oldText = try LocalToolsSupport.requiredRawString(input.old, name: "old")
        guard let newText = input.new else {
            throw LocalToolsFeatureError.missingArgument("new")
        }
        return try await LocalIOOffloader.run {
            let original = try String(contentsOf: path, encoding: .utf8)
            let replacement = try replacingAll(
                original, oldText: oldText, with: newText,
                notFoundMessage: "old text was not found in \(path.path)."
            )
            try replacement.contents.write(to: path, atomically: true, encoding: .utf8)
            return "Replaced \(replacement.replacements) occurrence(s) in \(path.path)."
        }
    }
}

struct LocalEditFileTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let old: String?
        let new: String?
    }

    static let name = "local.editFile"
    static let description = "Replaces exactly one occurrence of `old` with `new`. Read enough context to make `old` unique. Use `multiEdit` for multiple atomic edits to one file."
    static let inputSchema = buildInputSchema(
        [.string("path")] + CommonSchemaProperties.edit,
        required: ["path", "old", "new"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, context: context)
        let oldText = input.old ?? ""
        guard let newText = input.new else {
            throw LocalToolsFeatureError.missingArgument("new")
        }
        return try await LocalIOOffloader.run {
            let original = try String(contentsOf: path, encoding: .utf8)
            let result: LocalFileEditResult
            do {
                result = try LocalFileEditSupport.apply(old: oldText, new: newText, to: original)
            } catch let failure as LocalFileEditFailure {
                throw LocalToolsFeatureError.permissionDenied(editFailureMessage(failure, path: path.path))
            }
            try result.contents.write(to: path, atomically: true, encoding: .utf8)
            return LocalFileEditFeedback.single(path: path.path)
        }
    }
}

struct LocalMultiEditTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let edits: [Edit]?
    }

    struct Edit: Decodable, Sendable {
        let old: String?
        let new: String?
    }

    static let name = "local.multiEdit"
    static let description = "Applies ordered unique old/new replacements to one file and writes only if every edit succeeds."
    static let inputSchema = buildInputSchema(
        [.string("path"), .arrayOfObjects(
            "edits",
            properties: CommonSchemaProperties.edit,
            required: ["old", "new"]
        )],
        required: ["path", "edits"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, context: context)
        guard let edits = input.edits, !edits.isEmpty else {
            throw LocalToolsFeatureError.permissionDenied(
                "Multi-edit failed in \(path.path): edits must not be empty. No changes were written."
            )
        }
        // Read off the cooperative pool, then validate/transform on it (pure
        // CPU) so a long edit list can be cancelled between edits, then write
        // the result back off the pool.
        var contents = try await LocalIOOffloader.run {
            try String(contentsOf: path, encoding: .utf8)
        }
        for (index, edit) in edits.enumerated() {
            try Task.checkCancellation()
            let oldText = edit.old ?? ""
            guard let newText = edit.new else {
                throw LocalToolsFeatureError.permissionDenied(
                    "Multi-edit failed at edit \(index + 1) of \(edits.count) in \(path.path): new text is required. No changes were written."
                )
            }
            let result: LocalFileEditResult
            do {
                result = try LocalFileEditSupport.apply(old: oldText, new: newText, to: contents)
            } catch let failure as LocalFileEditFailure {
                throw LocalToolsFeatureError.permissionDenied(
                    multiEditFailureMessage(
                        failure,
                        edit: index + 1,
                        total: edits.count,
                        path: path.path
                    )
                )
            }
            contents = result.contents
        }
        try Task.checkCancellation()
        let finalContents = contents
        try await LocalIOOffloader.run {
            try finalContents.write(to: path, atomically: true, encoding: .utf8)
        }
        return LocalFileEditFeedback.multiple(path: path.path, editCount: edits.count)
    }
}

struct LocalAppendTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let content: String?
    }

    static let name = "local.append"
    static let description = "Appends UTF-8 text to a file."
    static let inputSchema = buildInputSchema(
        [.string("path"), .string("content")],
        required: ["path", "content"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        guard let content = input.content else {
            throw LocalToolsFeatureError.missingArgument("content")
        }
        let data = Data(content.utf8)
        return try await LocalIOOffloader.run {
            let descriptor = path.path.withCString {
                open($0, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            return "Appended \(data.count) bytes to \(path.path)."
        }
    }
}

struct LocalMakeDirectoryTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let createIntermediateDirectories: Bool?
    }

    static let name = "local.mkdir"
    static let description = "Creates a directory."
    static let inputSchema = buildInputSchema(
        [.string("path"), .boolean("createIntermediateDirectories")],
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, nil, context: context)
        let withIntermediateDirectories = input.createIntermediateDirectories ?? true
        return try await LocalIOOffloader.run {
            try FileManager.default.createDirectory(
                at: path,
                withIntermediateDirectories: withIntermediateDirectories
            )
            return "Created directory \(path.path)."
        }
    }
}

struct LocalDeleteTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let recursive: Bool?
    }

    static let name = "local.delete"
    static let description = "Deletes a file or directory. Directories require recursive=true."
    static let inputSchema = buildInputSchema(
        [.string("path"), .boolean("recursive")],
        required: ["path"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, nil, context: context)
        let recursive = input.recursive
        return try await LocalIOOffloader.run {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                return "Path does not exist: \(path.path)"
            }
            if isDirectory.boolValue && recursive != true {
                throw LocalToolsFeatureError.permissionDenied("Refusing to delete directory without recursive=true.")
            }
            try FileManager.default.removeItem(at: path)
            return "Deleted \(path.path)."
        }
    }
}

struct LocalMoveTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let sourcePath: String?
        let destinationPath: String?
        let overwriteExisting: Bool?
    }

    static let name = "local.move"
    static let description = "Moves or renames a file or directory."
    static let inputSchema = buildInputSchema(
        [.string("sourcePath"), .string("destinationPath"), .boolean("overwriteExisting")],
        required: ["sourcePath", "destinationPath"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        guard let sourcePath = input.sourcePath?.nilIfBlank,
              let destinationPath = input.destinationPath?.nilIfBlank else {
            throw LocalToolsFeatureError.missingArgument("sourcePath/destinationPath")
        }
        let sourceURL = context.resolvePath(sourcePath)
        let destinationURL = context.resolvePath(destinationPath)
        let overwriteExisting = input.overwriteExisting == true
        return try await LocalIOOffloader.run {
            let manager = FileManager.default
            guard manager.fileExists(atPath: sourceURL.path) else {
                throw LocalToolsFeatureError.permissionDenied("Source does not exist: \(sourceURL.path).")
            }
            guard manager.fileExists(atPath: destinationURL.path) else {
                try manager.moveItem(at: sourceURL, to: destinationURL)
                return "Moved \(sourceURL.path) to \(destinationURL.path)."
            }
            guard overwriteExisting else {
                throw LocalToolsFeatureError.permissionDenied("Destination exists. Set overwriteExisting=true.")
            }

            // `moveItem` cannot promise replacement semantics. Preserve the old
            // destination beside itself first, then restore it if moving the
            // source fails; the destination is never eagerly discarded.
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".zencode-move-backup-\(UUID().uuidString)")
            try manager.moveItem(at: destinationURL, to: backupURL)
            do {
                try manager.moveItem(at: sourceURL, to: destinationURL)
                try? manager.removeItem(at: backupURL)
                return "Moved \(sourceURL.path) to \(destinationURL.path)."
            } catch {
                var restorationError: Error?
                do {
                    if manager.fileExists(atPath: destinationURL.path) {
                        try manager.removeItem(at: destinationURL)
                    }
                    try manager.moveItem(at: backupURL, to: destinationURL)
                } catch {
                    restorationError = error
                }
                if let restorationError {
                    throw LocalToolsFeatureError.permissionDenied(
                        "Move failed and the destination backup could not be restored. Backup: \(backupURL.path). Move error: \(error.localizedDescription). Restore error: \(restorationError.localizedDescription)"
                    )
                }
                throw error
            }
        }
    }
}

// MARK: - Semantic presentation

extension LocalPwdTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Working directory", action: "Show", kind: .read, includesParameters: false)
    }
}

extension LocalListDirectoryTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Directory", action: "List", kind: .read, targetKeyPaths: ["path"], targetFormat: .path)
    }
}

extension LocalReadFileTool {
    static var presentation: ToolPresentationDefinition { .fileRead() }
}

extension LocalReadFilesTool {
    static var presentation: ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: "Files",
            action: "Read",
            kind: .read,
            target: .argument(["paths", "file_paths"], format: .stringList),
            sections: [
                .parameters(),
                .code(
                    label: "content",
                    value: .resultOutput(),
                    languageHint: .argument(
                        ["paths.0", "file_paths.0"],
                        format: .languageHint
                    )
                )
            ],
            summary: ToolPresentationSummaryDefinition(
                value: .resultOutput(),
                strategy: .numberedLineCount,
                label: "summary"
            )
        )
    }
}

extension LocalInspectFileTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "File structure", action: "Inspect", kind: .inspect, targetKeyPaths: ["file_path", "path"], targetFormat: .path)
    }
}

extension LocalWriteFileTool {
    static var presentation: ToolPresentationDefinition { .fileWrite() }
}

extension LocalReplaceTool {
    static var presentation: ToolPresentationDefinition { .fileEdit() }
}

extension LocalEditFileTool {
    static var presentation: ToolPresentationDefinition { .fileEdit() }
}

extension LocalMultiEditTool {
    static var presentation: ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: "File edits",
            action: "Edit",
            kind: .edit,
            target: .argument(["path"], format: .path),
            sections: [
                .parameters(),
                .list(label: "edits", value: .argument(["edits"], format: .json))
            ],
            summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
        )
    }
}

extension LocalAppendTool {
    static var presentation: ToolPresentationDefinition { .fileWrite(action: "Append") }
}

extension LocalMakeDirectoryTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Directory", action: "Create", kind: .create, targetKeyPaths: ["path"], targetFormat: .path)
    }
}

extension LocalDeleteTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Path", action: "Delete", kind: .delete, targetKeyPaths: ["path"], targetFormat: .path)
    }
}

extension LocalMoveTool {
    static var presentation: ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: "Path",
            action: "Move",
            kind: .move,
            target: .argument(["destinationPath"], format: .path),
            metadata: [
                ToolPresentationMetadataDefinition(label: "from", value: .argument(["sourcePath"], format: .path))
            ],
            sections: [.parameters()],
            summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
        )
    }
}
