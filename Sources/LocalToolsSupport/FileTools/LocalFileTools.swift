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
        [.string("path"), .boolean("includeHidden")]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let url = context.resolvePath(input.path ?? ".")
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
        let file_path: String?
        let oldString: String?
        let old_string: String?
        let newString: String?
        let new_string: String?
    }

    static let name = "local.replace"
    static let description = "Replaces all occurrences of oldString with newString in a UTF-8 text file."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases + CommonSchemaProperties.editStrings,
        required: ["path", "oldString", "newString"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let oldString = try LocalToolsSupport.requiredRawString(input.oldString, input.old_string, name: "oldString")
        guard let newString = input.newString ?? input.new_string else {
            throw LocalToolsFeatureError.missingArgument("newString")
        }
        return try await LocalIOOffloader.run {
            let original = try String(contentsOf: path, encoding: .utf8)
            // Count without materializing the full split array.
            let occurrences = original.ranges(of: oldString).count
            guard occurrences > 0 else {
                throw LocalToolsFeatureError.permissionDenied("oldString was not found in \(path.path).")
            }
            let updated = original.replacingOccurrences(of: oldString, with: newString)
            try updated.write(to: path, atomically: true, encoding: .utf8)
            return "Replaced \(occurrences) occurrence(s) in \(path.path)."
        }
    }
}

struct LocalEditFileTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let oldString: String?
        let old_string: String?
        let newString: String?
        let new_string: String?
        let replaceAll: Bool?
        let replace_all: Bool?
    }

    static let name = "local.editFile"
    static let description = "Applies a targeted string replacement in a file. By default exactly one occurrence must match; set replaceAll=true to update every occurrence."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases + CommonSchemaProperties.editStrings
            + [.boolean("replaceAll"), .boolean("replace_all")],
        required: ["path", "oldString", "newString"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let oldString = try LocalToolsSupport.requiredRawString(input.oldString, input.old_string, name: "oldString")
        guard let newString = input.newString ?? input.new_string else {
            throw LocalToolsFeatureError.missingArgument("newString")
        }
        let replaceAll = input.replaceAll ?? input.replace_all ?? false
        return try await LocalIOOffloader.run {
            let original = try String(contentsOf: path, encoding: .utf8)
            let occurrences = original.ranges(of: oldString).count
            guard occurrences > 0 else {
                throw LocalToolsFeatureError.permissionDenied("oldString was not found in \(path.path).")
            }
            if !replaceAll && occurrences != 1 {
                throw LocalToolsFeatureError.permissionDenied("oldString matched \(occurrences) times. Set replaceAll=true or provide a unique string.")
            }
            let updated = replaceAll
                ? original.replacingOccurrences(of: oldString, with: newString)
                : original.replacingFirstOccurrence(of: oldString, with: newString)
            try updated.write(to: path, atomically: true, encoding: .utf8)
            return "Updated \(path.path). Replacements: \(replaceAll ? occurrences : 1)."
        }
    }
}

struct LocalMultiEditTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let edits: [Edit]
    }

    struct Edit: Decodable, Sendable {
        let oldString: String?
        let old_string: String?
        let newString: String?
        let new_string: String?
        let replaceAll: Bool?
        let replace_all: Bool?
    }

    static let name = "local.multiEdit"
    static let description = "Applies multiple targeted edits to the same file in order."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.pathAliases
            + [.arrayOfObjects("edits", properties: CommonSchemaProperties.editStrings
                + [.boolean("replaceAll"), .boolean("replace_all")])],
        required: ["path", "edits"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        guard !input.edits.isEmpty else {
            throw LocalToolsFeatureError.missingArgument("edits")
        }
        // Read off the cooperative pool, then validate/transform on it (pure
        // CPU) so a long edit list can be cancelled between edits, then write
        // the result back off the pool.
        var contents = try await LocalIOOffloader.run {
            try String(contentsOf: path, encoding: .utf8)
        }
        var totalReplacements = 0
        for (index, edit) in input.edits.enumerated() {
            try Task.checkCancellation()
            let oldString = try LocalToolsSupport.requiredRawString(
                edit.oldString,
                edit.old_string,
                name: "edits[\(index)].oldString"
            )
            guard let newString = edit.newString ?? edit.new_string else {
                throw LocalToolsFeatureError.missingArgument("edits[\(index)].newString")
            }
            let replaceAll = edit.replaceAll ?? edit.replace_all ?? false
            let occurrences = contents.components(separatedBy: oldString).count - 1
            guard occurrences > 0 else {
                throw LocalToolsFeatureError.permissionDenied("oldString was not found in \(path.path): \(oldString)")
            }
            if !replaceAll && occurrences != 1 {
                throw LocalToolsFeatureError.permissionDenied("oldString matched \(occurrences) times. Set replaceAll=true or provide a unique string.")
            }
            contents = replaceAll
                ? contents.replacingOccurrences(of: oldString, with: newString)
                : contents.replacingFirstOccurrence(of: oldString, with: newString)
            totalReplacements += replaceAll ? occurrences : 1
        }
        let finalContents = contents
        try await LocalIOOffloader.run {
            try finalContents.write(to: path, atomically: true, encoding: .utf8)
        }
        return "Edited \(totalReplacements) occurrence(s) across \(input.edits.count) edit(s) in \(path.path)."
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
        .standard(title: "Files", action: "Read", kind: .read, targetKeyPaths: ["paths", "file_paths"], targetFormat: .stringList)
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
            target: .argument(["file_path", "path"], format: .path),
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
