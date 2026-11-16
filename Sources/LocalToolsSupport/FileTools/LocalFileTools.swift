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
    static let inputSchema = buildInputSchema([.string("path"), .boolean("includeHidden")], required: ["path"])

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
        if let read = ClientTextFileSystem.current?.read {
            return LocalToolsSupport.renderFileText(try await read(url), offset: offset, limit: limit)
        }
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
        let primaryPaths = input.paths?.compactMap { $0.nilIfBlank } ?? []
        let fallbackPaths = input.file_paths?.compactMap { $0.nilIfBlank } ?? []
        let rawPaths = primaryPaths.isEmpty ? fallbackPaths : primaryPaths
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
                let body: String
                if let read = ClientTextFileSystem.current?.read {
                    body = LocalToolsSupport.renderFileText(try await read(url), offset: offset, limit: limit)
                } else {
                    body = try await LocalIOOffloader.run {
                        try LocalToolsSupport.readFile(url, offset: offset, limit: limit)
                    }
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
        if let write = ClientTextFileSystem.current?.write {
            // Parent-directory handling belongs to the client, not local disk.
            try await write(path, content)
            return "Wrote \(path.path) (\(byteCount) bytes) through the client."
        }
        return try await LocalIOOffloader.run {
            if createDirectories {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            try LocalOperationWrite.write(content, to: path)
            return "Wrote \(path.path) (\(byteCount) bytes)."
        }
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
    static let inputSchema = buildInputSchema([.string("path"), .string("content")], required: ["path", "content"])

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        guard let content = input.content else {
            throw LocalToolsFeatureError.missingArgument("content")
        }
        let data = Data(content.utf8)
        return try await LocalIOOffloader.run {
            try LocalOperationWrite.serialized {
            let existed = LocalOperationWrite.existsForEvidence(path)
            let before = LocalOperationWrite.snapshot(path)
            try LocalOperationWrite.append(data, to: path)
            let after: String?
            if OperationFileChangeRecorder.current != nil,
               content.utf8.count <= OperationFileChangeRecorder.maximumSnapshotBytes,
               (before?.count ?? 0) + content.utf8.count <= OperationFileChangeRecorder.maximumSnapshotBytes {
                after = before.flatMap { String(data: $0, encoding: .utf8) }.map { $0 + content }
                    ?? (existed ? nil : content)
            } else {
                after = nil
            }
            // A missing after-image is not a deletion: force textual fallback.
            LocalOperationWrite.record(path: path, existed: after == nil ? true : existed,
                                       before: after == nil ? nil : before, after: after)
            return "Appended \(data.count) bytes to \(path.path)."
            }
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
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: withIntermediateDirectories)
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
    static let inputSchema = buildInputSchema([.string("path"), .boolean("recursive")], required: ["path"])

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, nil, context: context)
        let recursive = input.recursive
        return try await LocalIOOffloader.run {
            try LocalOperationWrite.serialized {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                return "Path does not exist: \(path.path)"
            }
            if isDirectory.boolValue && recursive != true {
                throw LocalToolsFeatureError.permissionDenied("Refusing to delete directory without recursive=true.")
            }
            let before = LocalOperationWrite.snapshot(path)
            try FileManager.default.removeItem(at: path)
            LocalOperationWrite.record(path: path, existed: true, before: before, after: nil)
            return "Deleted \(path.path)."
            }
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
            try LocalOperationWrite.serialized {
            let manager = FileManager.default
            let sourceData = LocalOperationWrite.snapshot(sourceURL)
            let destinationExisted = LocalOperationWrite.existsForEvidence(destinationURL)
            let destinationData = LocalOperationWrite.snapshot(destinationURL)
            func recordMove() {
                LocalOperationWrite.record(path: sourceURL, existed: true, before: sourceData, after: nil)
                if let text = sourceData.flatMap({ String(data: $0, encoding: .utf8) }), !text.contains("\0") {
                    LocalOperationWrite.record(path: destinationURL, existed: destinationExisted, before: destinationData, after: text)
                } else {
                    LocalOperationWrite.record(path: destinationURL, existed: true, before: nil, after: nil)
                }
            }
            guard manager.fileExists(atPath: sourceURL.path) else {
                throw LocalToolsFeatureError.permissionDenied("Source does not exist: \(sourceURL.path).")
            }
            guard manager.fileExists(atPath: destinationURL.path) else {
                try manager.moveItem(at: sourceURL, to: destinationURL)
                recordMove()
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
                recordMove()
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
}

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
                    languageHint: .argument(["paths.0", "file_paths.0"], format: .languageHint)
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
