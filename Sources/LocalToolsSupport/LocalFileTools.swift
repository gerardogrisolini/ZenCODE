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


struct LocalPwdTool: FeatureTool {
    struct Input: Decodable, Sendable {}

    static let name = "local.pwd"
    static let description = "Returns the current working directory used by local tools."
    static let inputSchema = #"{"type":"object","properties":{}}"#

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
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"includeHidden":{"type":"boolean"}}}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try LocalToolsSupport.listDirectory(
            context.resolvePath(input.path ?? "."),
            includeHidden: input.includeHidden ?? false
        )
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
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"offset":{"type":"number"},"limit":{"type":"number"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try LocalToolsSupport.readFile(
            LocalToolsSupport.requiredPath(input.path, input.file_path, context: context),
            offset: input.offset,
            limit: input.limit
        )
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
    static let inputSchema = #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"}},"file_paths":{"type":"array","items":{"type":"string"}},"offset":{"type":"number"},"limit":{"type":"number"}},"required":["paths"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let rawPaths = (input.paths ?? input.file_paths ?? [])
            .compactMap { $0.nilIfBlank }
        guard !rawPaths.isEmpty else {
            throw LocalToolsFeatureError.missingArgument("paths")
        }
        var sections: [String] = []
        for rawPath in rawPaths {
            let url = context.resolvePath(rawPath)
            do {
                let body = try LocalToolsSupport.readFile(
                    url,
                    offset: input.offset,
                    limit: input.limit
                )
                sections.append("===== \(url.path) =====\n\(body)")
            } catch {
                sections.append("===== \(url.path) =====\n<error: \(error.localizedDescription)>")
            }
        }
        return sections.joined(separator: "\n\n")
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
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"content":{"type":"string"},"createDirectories":{"type":"boolean"}},"required":["file_path","content"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let content = input.content ?? ""
        if input.createDirectories == true {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try content.write(to: path, atomically: true, encoding: .utf8)
        return "Wrote \(path.path) (\(content.utf8.count) bytes)."
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
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"}},"required":["path","oldString","newString"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let oldString = try LocalToolsSupport.requiredRawString(input.oldString, input.old_string, name: "oldString")
        let newString = input.newString ?? input.new_string ?? ""
        let original = try String(contentsOf: path, encoding: .utf8)
        let occurrences = original.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            throw LocalToolsFeatureError.permissionDenied("oldString was not found in \(path.path).")
        }
        let updated = original.replacingOccurrences(of: oldString, with: newString)
        try updated.write(to: path, atomically: true, encoding: .utf8)
        return "Replaced \(occurrences) occurrence(s) in \(path.path)."
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
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"},"replaceAll":{"type":"boolean"},"replace_all":{"type":"boolean"}},"required":["path","oldString","newString"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let oldString = try LocalToolsSupport.requiredRawString(input.oldString, input.old_string, name: "oldString")
        let newString = input.newString ?? input.new_string ?? ""
        let replaceAll = input.replaceAll ?? input.replace_all ?? false
        let original = try String(contentsOf: path, encoding: .utf8)
        let occurrences = original.components(separatedBy: oldString).count - 1
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
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"},"replaceAll":{"type":"boolean"},"replace_all":{"type":"boolean"}}}}},"required":["path","edits"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        guard !input.edits.isEmpty else {
            throw LocalToolsFeatureError.missingArgument("edits")
        }
        var contents = try String(contentsOf: path, encoding: .utf8)
        var totalReplacements = 0
        for (index, edit) in input.edits.enumerated() {
            let oldString = try LocalToolsSupport.requiredRawString(
                edit.oldString,
                edit.old_string,
                name: "edits[\(index)].oldString"
            )
            let newString = edit.newString ?? edit.new_string ?? ""
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
        try contents.write(to: path, atomically: true, encoding: .utf8)
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
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let content = input.content ?? ""
        let data = Data(content.utf8)
        if FileManager.default.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: path)
        }
        return "Appended \(data.count) bytes to \(path.path)."
    }
}

struct LocalMakeDirectoryTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let createIntermediateDirectories: Bool?
    }

    static let name = "local.mkdir"
    static let description = "Creates a directory."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"createIntermediateDirectories":{"type":"boolean"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, nil, context: context)
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: input.createIntermediateDirectories ?? true
        )
        return "Created directory \(path.path)."
    }
}

struct LocalDeleteTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let recursive: Bool?
    }

    static let name = "local.delete"
    static let description = "Deletes a file or directory. Directories require recursive=true."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, nil, context: context)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            return "Path does not exist: \(path.path)"
        }
        if isDirectory.boolValue && input.recursive != true {
            throw LocalToolsFeatureError.permissionDenied("Refusing to delete directory without recursive=true.")
        }
        try FileManager.default.removeItem(at: path)
        return "Deleted \(path.path)."
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
    static let inputSchema = #"{"type":"object","properties":{"sourcePath":{"type":"string"},"destinationPath":{"type":"string"},"overwriteExisting":{"type":"boolean"}},"required":["sourcePath","destinationPath"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        guard let sourcePath = input.sourcePath?.nilIfBlank,
              let destinationPath = input.destinationPath?.nilIfBlank else {
            throw LocalToolsFeatureError.missingArgument("sourcePath/destinationPath")
        }
        let sourceURL = context.resolvePath(sourcePath)
        let destinationURL = context.resolvePath(destinationPath)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard input.overwriteExisting == true else {
                throw LocalToolsFeatureError.permissionDenied("Destination exists. Set overwriteExisting=true.")
            }
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return "Moved \(sourceURL.path) to \(destinationURL.path)."
    }
}

struct LocalApplyPatchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let patch: String?
        let diff: String?
    }

    static let name = "local.applyPatch"
    static let description = "Applies a unified diff that may span multiple files. All hunks are validated in memory first and written atomically: if any hunk fails to match, no file is changed."
    static let inputSchema = #"{"type":"object","properties":{"patch":{"type":"string"},"diff":{"type":"string"}},"required":["patch"]}"#

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let rawPatch = try LocalToolsSupport.requiredRawString(input.patch, input.diff, name: "patch")
        if LocalToolsSupport.isBeginPatchFormat(rawPatch) {
            let filePatches = try LocalToolsSupport.parseBeginPatch(rawPatch)
            guard !filePatches.isEmpty else {
                throw LocalToolsFeatureError.permissionDenied("No file sections were found in the patch.")
            }

            // Phase 1: validate and compute all new contents without writing.
            var planned: [(url: URL, newContent: String?, isDelete: Bool)] = []
            for filePatch in filePatches {
                let url = context.resolvePath(filePatch.path)
                let result = try LocalToolsSupport.applyBeginPatch(filePatch, at: url)
                planned.append((url, result.newContent, result.isDelete))
            }

            // Phase 2: commit.
            var changed: [String] = []
            for entry in planned {
                if entry.isDelete {
                    if FileManager.default.fileExists(atPath: entry.url.path) {
                        try FileManager.default.removeItem(at: entry.url)
                    }
                    changed.append("deleted \(entry.url.path)")
                } else if let content = entry.newContent {
                    try FileManager.default.createDirectory(
                        at: entry.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try content.write(to: entry.url, atomically: true, encoding: .utf8)
                    changed.append("patched \(entry.url.path)")
                }
            }
            return "Applied patch to \(changed.count) file(s):\n" + changed.joined(separator: "\n")
        }

        let filePatches = try LocalToolsSupport.parseUnifiedDiff(rawPatch)
        guard !filePatches.isEmpty else {
            throw LocalToolsFeatureError.permissionDenied("No file sections were found in the patch.")
        }

        // Phase 1: validate and compute all new contents without writing.
        var planned: [(url: URL, newContent: String?, isDelete: Bool)] = []
        for filePatch in filePatches {
            let url = context.resolvePath(filePatch.path)
            let result = try LocalToolsSupport.applyFilePatch(filePatch, at: url)
            planned.append((url, result.newContent, result.isDelete))
        }

        // Phase 2: commit.
        var changed: [String] = []
        for entry in planned {
            if entry.isDelete {
                if FileManager.default.fileExists(atPath: entry.url.path) {
                    try FileManager.default.removeItem(at: entry.url)
                }
                changed.append("deleted \(entry.url.path)")
            } else if let content = entry.newContent {
                try FileManager.default.createDirectory(
                    at: entry.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(to: entry.url, atomically: true, encoding: .utf8)
                changed.append("patched \(entry.url.path)")
            }
        }
        return "Applied patch to \(changed.count) file(s):\n" + changed.joined(separator: "\n")
    }
}
