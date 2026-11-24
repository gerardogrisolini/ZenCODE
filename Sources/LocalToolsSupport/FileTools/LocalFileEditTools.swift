//
//  LocalFileEditTools.swift
//  ZenCODE
//
//  The in-place edit tools local.replace, local.edit, and local.multiEdit
//  with their presentations and failure messages.
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
    return (contents.replacingOccurrences(of: oldText, with: newText), occurrences)
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

private func multiEditFailureMessage(_ failure: LocalFileEditFailure, edit: Int, total: Int, path: String) -> String {
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
        if let edit = ClientTextFileSystem.current?.edit {
            let result = try await edit(path) { original in
                try replacingAll(original, oldText: oldText, with: newText,
                    notFoundMessage: "old text was not found in \(path.path).").contents
            }
            return "Replaced \(result.before.ranges(of: oldText).count) occurrence(s) in \(path.path)."
        }
        return try await LocalIOOffloader.run {
            let original = try String(contentsOf: path, encoding: .utf8)
            let replacement = try replacingAll(
                original, oldText: oldText, with: newText,
                notFoundMessage: "old text was not found in \(path.path)."
            )
            try LocalOperationWrite.write(replacement.contents, to: path)
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

    static let name = "local.edit"
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
        if let edit = ClientTextFileSystem.current?.edit {
            _ = try await edit(path) { original in
                do {
                    return try LocalFileEditSupport.apply(old: oldText, new: newText, to: original).contents
                } catch let failure as LocalFileEditFailure {
                    throw LocalToolsFeatureError.permissionDenied(editFailureMessage(failure, path: path.path))
                }
            }
            return LocalFileEditFeedback.single(path: path.path)
        }
        return try await LocalIOOffloader.run {
            let original = try String(contentsOf: path, encoding: .utf8)
            let result: LocalFileEditResult
            do {
                result = try LocalFileEditSupport.apply(old: oldText, new: newText, to: original)
            } catch let failure as LocalFileEditFailure {
                throw LocalToolsFeatureError.permissionDenied(editFailureMessage(failure, path: path.path))
            }
            try LocalOperationWrite.write(result.contents, to: path)
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
        [.string("path"), .arrayOfObjects("edits", properties: CommonSchemaProperties.edit, required: ["old", "new"])],
        required: ["path", "edits"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, context: context)
        guard let edits = input.edits, !edits.isEmpty else {
            throw LocalToolsFeatureError.permissionDenied(
                "Multi-edit failed in \(path.path): edits must not be empty. No changes were written."
            )
        }
        if let edit = ClientTextFileSystem.current?.edit {
            _ = try await edit(path) { original in
                try Self.applying(edits, to: original, path: path.path)
            }
            return LocalFileEditFeedback.multiple(path: path.path, editCount: edits.count)
        }
        // Read off the cooperative pool, then validate/transform on it (pure
        // CPU) so a long edit list can be cancelled between edits, then write
        // the result back off the pool.
        let original = try await LocalIOOffloader.run {
            try String(contentsOf: path, encoding: .utf8)
        }
        let finalContents = try Self.applying(edits, to: original, path: path.path)
        try Task.checkCancellation()
        try await LocalIOOffloader.run {
            try LocalOperationWrite.write(finalContents, to: path)
        }
        return LocalFileEditFeedback.multiple(path: path.path, editCount: edits.count)
    }

    private static func applying(_ edits: [Edit], to original: String, path: String) throws -> String {
        var contents = original
        for (index, edit) in edits.enumerated() {
            try Task.checkCancellation()
            let oldText = edit.old ?? ""
            guard let newText = edit.new else {
                throw LocalToolsFeatureError.permissionDenied(
                    "Multi-edit failed at edit \(index + 1) of \(edits.count) in \(path): new text is required. No changes were written."
                )
            }
            let result: LocalFileEditResult
            do {
                result = try LocalFileEditSupport.apply(old: oldText, new: newText, to: contents)
            } catch let failure as LocalFileEditFailure {
                throw LocalToolsFeatureError.permissionDenied(
                    multiEditFailureMessage(failure, edit: index + 1, total: edits.count, path: path)
                )
            }
            contents = result.contents
        }
        return contents
    }
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
            sections: [.parameters(), .list(label: "edits", value: .argument(["edits"], format: .json))],
            summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
        )
    }
}
