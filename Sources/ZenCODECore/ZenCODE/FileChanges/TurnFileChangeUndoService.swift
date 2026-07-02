//
//  TurnFileChangeUndoService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum TurnFileChangeUndoService {
    @discardableResult
    public static func undoLatest(
        summary: TurnFileChangeSummary?,
        baseDirectoryURL: URL
    ) async throws -> TurnFileChangeSummary {
        guard let summary else {
            throw TurnFileChangeUndoError.noTrackedFileChanges
        }

        guard summary.canUndo else {
            throw TurnFileChangeUndoError.unavailable
        }

        try await undo(summary: summary, baseDirectoryURL: baseDirectoryURL)
        return summary
    }

    public static func undo(
        summary: TurnFileChangeSummary,
        baseDirectoryURL: URL
    ) async throws {
        do {
            if try await undoUsingPatchIfPossible(
                summary: summary,
                baseDirectoryURL: baseDirectoryURL
            ) {
                return
            }
        } catch {
            SwiftMLXLogger.warning(
                .turnFileChangeTracker,
                "Patch undo failed, falling back to captured file snapshots: \(error.localizedDescription)"
            )
        }

        try restoreFilesFromSnapshots(
            summary: summary,
            baseDirectoryURL: baseDirectoryURL
        )
    }

    static func undoUsingPatchIfPossible(
        summary: TurnFileChangeSummary,
        baseDirectoryURL: URL
    ) async throws -> Bool {
        guard summary.entries.allSatisfy({ $0.patch?.isEmpty == false }) else {
            return false
        }

        let patch = summary.entries
            .compactMap(\.patch)
            .joined(separator: "\n")
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        #if canImport(Darwin) || canImport(Glibc)
        let patchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).patch")
        try patch.write(to: patchURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: patchURL)
        }

        let result = try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: [
                "apply",
                "--reverse",
                "--whitespace=nowarn",
                patchURL.path
            ],
            workingDirectory: baseDirectoryURL.standardizedFileURL,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 20
        )

        guard result.exitCode == 0 else {
            let fallbackMessage = result.timedOut
                ? "git apply --reverse timed out."
                : "git apply --reverse failed."
            let errorMessage = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "zencode.undo",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage.isEmpty == false
                        ? errorMessage
                        : fallbackMessage
                ]
            )
        }

                // `git apply` can exit 0 while silently skipping patches whose paths
        // fall outside the current repository subtree (it prints
        // "Skipped patch ..." and succeeds). Verify the undo actually landed
        // so callers can fall back to captured snapshots when it did not.
        guard undoWasApplied(summary: summary, baseDirectoryURL: baseDirectoryURL) else {
            throw NSError(
                domain: "zencode.undo",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "git apply --reverse succeeded but one or more files were not reverted."
                ]
            )
        }

        return true
        #else
        return false
        #endif
    }

    static func undoWasApplied(
        summary: TurnFileChangeSummary,
        baseDirectoryURL: URL
    ) -> Bool {
        for entry in summary.entries {
            let fileURL = fileURLForUndoEntry(entry, baseDirectoryURL: baseDirectoryURL)

            switch entry.existedBefore {
            case false:
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: fileURL.path,
                    isDirectory: &isDirectory
                )
                if exists && !isDirectory.boolValue {
                    return false
                }
            case true:
                guard let beforeData = entry.beforeData else {
                    continue
                }
                guard let currentData = try? Data(contentsOf: fileURL),
                      currentData == beforeData else {
                    return false
                }
            case nil:
                continue
            }
        }

        return true
    }

    static func restoreFilesFromSnapshots(
        summary: TurnFileChangeSummary,
        baseDirectoryURL: URL
    ) throws {
        for entry in summary.entries {
            let fileURL = fileURLForUndoEntry(entry, baseDirectoryURL: baseDirectoryURL)

            if entry.existedBefore == false {
                try removeCreatedFileIfNeeded(at: fileURL)
                continue
            }

            guard let beforeData = entry.beforeData else {
                continue
            }

            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try beforeData.write(to: fileURL, options: .atomic)
        }
    }

    static func removeCreatedFileIfNeeded(at fileURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ) else {
            return
        }

        guard !isDirectory.boolValue else {
            return
        }

        try FileManager.default.removeItem(at: fileURL)
    }

    static func fileURLForUndoEntry(
        _ entry: TurnFileChangeSummary.Entry,
        baseDirectoryURL: URL
    ) -> URL {
        if entry.path.hasPrefix("/") {
            return URL(fileURLWithPath: entry.path).standardizedFileURL
        }

        return baseDirectoryURL
            .standardizedFileURL
            .appendingPathComponent(entry.path)
            .standardizedFileURL
    }
}
