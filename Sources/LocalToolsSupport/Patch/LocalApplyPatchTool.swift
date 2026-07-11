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


struct LocalApplyPatchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let patch: String?
        let diff: String?
    }

    static let name = "local.applyPatch"
    static let description = "Applies a unified diff that may span multiple files. All hunks are validated in memory first and written atomically: if any hunk fails to match, no file is changed."
    static let inputSchema = buildInputSchema(
        [.string("patch"), .string("diff")],
        required: ["patch"]
    )

    private struct PlannedPatchChange {
        let url: URL
        let newContent: String?
        let isDelete: Bool
    }

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let rawPatch = try LocalToolsSupport.requiredRawString(input.patch, input.diff, name: "patch")
        let plannedChanges = try plannedPatchChanges(for: rawPatch, context: context)
        let changedPaths = try commit(plannedChanges)
        return "Applied patch to \(changedPaths.count) file(s):\n" + changedPaths.joined(separator: "\n")
    }

    private func plannedPatchChanges(
        for rawPatch: String,
        context: FeatureContext
    ) throws -> [PlannedPatchChange] {
        if LocalToolsSupport.isBeginPatchFormat(rawPatch) {
            return try plannedBeginPatchChanges(for: rawPatch, context: context)
        }
        return try plannedUnifiedDiffChanges(for: rawPatch, context: context)
    }

    private func plannedBeginPatchChanges(
        for rawPatch: String,
        context: FeatureContext
    ) throws -> [PlannedPatchChange] {
        let filePatches = try LocalToolsSupport.parseBeginPatch(rawPatch)
        try requireNonEmptyFilePatches(filePatches)
        return try filePatches.map { filePatch in
            let url = context.resolvePath(filePatch.path)
            let result = try LocalToolsSupport.applyBeginPatch(filePatch, at: url)
            return PlannedPatchChange(url: url, newContent: result.newContent, isDelete: result.isDelete)
        }
    }

    private func plannedUnifiedDiffChanges(
        for rawPatch: String,
        context: FeatureContext
    ) throws -> [PlannedPatchChange] {
        let filePatches = try LocalToolsSupport.parseUnifiedDiff(rawPatch)
        try requireNonEmptyFilePatches(filePatches)
        return try filePatches.map { filePatch in
            let url = context.resolvePath(filePatch.path)
            let result = try LocalToolsSupport.applyFilePatch(filePatch, at: url)
            return PlannedPatchChange(url: url, newContent: result.newContent, isDelete: result.isDelete)
        }
    }

    private func requireNonEmptyFilePatches(_ filePatches: some Collection) throws {
        guard !filePatches.isEmpty else {
            throw LocalToolsFeatureError.permissionDenied("No file sections were found in the patch.")
        }
    }

    private func commit(_ changes: [PlannedPatchChange]) throws -> [String] {
        var changedPaths: [String] = []
        for change in changes {
            if change.isDelete {
                try deleteIfPresent(change.url)
                changedPaths.append("deleted \(change.url.path)")
            } else if let content = change.newContent {
                try write(content, to: change.url)
                changedPaths.append("patched \(change.url.path)")
            }
        }
        return changedPaths
    }

    private func deleteIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
