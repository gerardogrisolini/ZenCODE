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

struct LocalApplyPatchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let patch: String?
        let diff: String?
    }

    static let name = "local.applyPatch"
    static let description = "Applies a unified diff that may span multiple files. All hunks are validated before commit; writes use same-directory staging and rollback is attempted on every failure."
    static let inputSchema = buildInputSchema(
        [.string("patch"), .string("diff")],
        required: ["patch"]
    )

    private struct PlannedPatchChange {
        let url: URL
        let newContent: String?
        let isDelete: Bool
    }

    private struct StagedPatchChange {
        let change: PlannedPatchChange
        let temporaryURL: URL?
        let backupURL: URL?
        let hadOriginal: Bool
    }

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let rawPatch = try LocalToolsSupport.requiredRawString(input.patch, input.diff, name: "patch")
        // Parsing and hunk validation happen before staging; the complete commit
        // then remains off the cooperative pool with no await/reentrancy point.
        return try await LocalIOOffloader.run { [self] in
            let plannedChanges = try plannedPatchChanges(for: rawPatch, context: context)
            let changedPaths = try commit(plannedChanges)
            return "Applied patch to \(changedPaths.count) file(s):\n" + changedPaths.joined(separator: "\n")
        }
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

    /// Commits a fully validated patch using temporary siblings and per-file
    /// backups. POSIX has no portable all-files atomic rename, so a failure is
    /// rolled back synchronously. If rollback itself fails, the error explicitly
    /// lists paths that may have been committed rather than claiming atomicity.
    private func commit(_ changes: [PlannedPatchChange]) throws -> [String] {
        let duplicatePaths = Dictionary(grouping: changes, by: { $0.url.standardizedFileURL.path })
            .filter { $0.value.count > 1 }
            .map(\.key)
        guard duplicatePaths.isEmpty else {
            throw LocalToolsFeatureError.permissionDenied(
                "Patch contains multiple changes for the same path: \(duplicatePaths.sorted().joined(separator: ", "))."
            )
        }

        var staged: [StagedPatchChange] = []
        do {
            for change in changes {
                staged.append(try stage(change))
            }
        } catch {
            cleanup(staged)
            throw error
        }

        var committed: [StagedPatchChange] = []
        do {
            for stagedChange in staged {
                try apply(stagedChange)
                committed.append(stagedChange)
            }
        } catch {
            let rollbackFailures = rollback(staged.reversed())
            let committedPaths = committed.map(\.change.url.path).joined(separator: ", ")
            if rollbackFailures.isEmpty {
                cleanup(staged)
                throw LocalToolsFeatureError.permissionDenied(
                    "Patch commit failed and all committed changes were rolled back. Paths touched: \(committedPaths.isEmpty ? "<none>" : committedPaths). Underlying error: \(error.localizedDescription)"
                )
            }
            // Leave same-directory backups in place when rollback itself fails;
            // deleting them here would turn a recoverable partial commit into data
            // loss. The reported paths identify the files requiring recovery.
            throw LocalToolsFeatureError.permissionDenied(
                "Patch commit failed; rollback could not restore: \(rollbackFailures.joined(separator: ", ")). Changes that may have been committed: \(committedPaths.isEmpty ? "<none>" : committedPaths). Underlying error: \(error.localizedDescription)"
            )
        }

        let changedPaths = staged.map { stagedChange in
            stagedChange.change.isDelete
                ? "deleted \(stagedChange.change.url.path)"
                : "patched \(stagedChange.change.url.path)"
        }
        cleanup(staged)
        return changedPaths
    }

    private func stage(_ change: PlannedPatchChange) throws -> StagedPatchChange {
        let manager = FileManager.default
        let hadOriginal = manager.fileExists(atPath: change.url.path)
        let directory = change.url.deletingLastPathComponent()
        let identifier = UUID().uuidString
        let backupURL = hadOriginal
            ? directory.appendingPathComponent(".zencode-patch-backup-\(identifier)")
            : nil

        if let backupURL {
            try manager.copyItem(at: change.url, to: backupURL)
        }

        guard !change.isDelete, let content = change.newContent else {
            return StagedPatchChange(
                change: change,
                temporaryURL: nil,
                backupURL: backupURL,
                hadOriginal: hadOriginal
            )
        }

        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = directory.appendingPathComponent(".zencode-patch-stage-\(identifier)")
            try Data(content.utf8).write(to: temporaryURL, options: .atomic)
            return StagedPatchChange(
                change: change,
                temporaryURL: temporaryURL,
                backupURL: backupURL,
                hadOriginal: hadOriginal
            )
        } catch {
            if let backupURL {
                try? manager.removeItem(at: backupURL)
            }
            throw error
        }
    }

    private func apply(_ staged: StagedPatchChange) throws {
        let manager = FileManager.default
        let url = staged.change.url
        if staged.change.isDelete {
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            return
        }

        guard let temporaryURL = staged.temporaryURL else {
            throw LocalToolsFeatureError.permissionDenied("Patch staging failed for \(url.path).")
        }
        if manager.fileExists(atPath: url.path) {
            // Atomically replace the destination with the staged file. The
            // temporary file lives in the destination's own directory, so both
            // paths share a filesystem and POSIX `rename` swaps a regular file
            // in place without a window in which the destination is missing.
            // `FileManager.replaceItemAt` is avoided because its Linux
            // (corelibs-foundation) implementation throws a "file doesn't exist"
            // error even when both paths exist.
            try atomicSwap(temporaryURL: temporaryURL, destination: url)
        } else {
            try manager.moveItem(at: temporaryURL, to: url)
        }
    }

    /// Atomically moves `temporaryURL` onto `destination`, overwriting it. The
    /// caller guarantees the two paths share a directory (hence a filesystem),
    /// so `rename` never fails with `EXDEV` and atomically replaces an existing
    /// regular file. `errno` is captured inside the closure, immediately after
    /// the failing call, before any other library code can overwrite it.
    private func atomicSwap(temporaryURL: URL, destination: URL) throws {
        var capturedErrno: Int32 = 0
        let status = temporaryURL.path.withCString { source -> Int32 in
            destination.path.withCString { target -> Int32 in
                let result = rename(source, target)
                if result != 0 { capturedErrno = errno }
                return result
            }
        }
        guard status == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(capturedErrno),
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not replace \(destination.path) with the staged patch file (errno \(capturedErrno))."
                ]
            )
        }
    }

    private func rollback(_ stagedChanges: ReversedCollection<[StagedPatchChange]>) -> [String] {
        let manager = FileManager.default
        var failures: [String] = []
        for staged in stagedChanges {
            do {
                let url = staged.change.url
                if manager.fileExists(atPath: url.path) {
                    try manager.removeItem(at: url)
                }
                if staged.hadOriginal, let backupURL = staged.backupURL,
                   manager.fileExists(atPath: backupURL.path) {
                    try manager.moveItem(at: backupURL, to: url)
                }
            } catch {
                failures.append(staged.change.url.path)
            }
        }
        return failures
    }

    private func cleanup(_ staged: [StagedPatchChange]) {
        let manager = FileManager.default
        for stagedChange in staged {
            if let temporaryURL = stagedChange.temporaryURL {
                try? manager.removeItem(at: temporaryURL)
            }
            if let backupURL = stagedChange.backupURL {
                try? manager.removeItem(at: backupURL)
            }
        }
    }
}


extension LocalApplyPatchTool {
    static var presentation: ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: "Patch",
            action: "Apply",
            kind: .edit,
            sections: [
                .parameters(),
                .code(
                    label: "patch",
                    value: .argument(["patch", "diff"], format: .text),
                    languageHint: .literal("diff")
                )
            ],
            summary: ToolPresentationSummaryDefinition(
                value: .resultSummary(),
                strategy: .firstLine,
                label: "summary"
            )
        )
    }
}
