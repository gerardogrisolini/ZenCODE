//
//  TurnFileChangeTracker+PlatformDiff.swift
//  ZenCODE
//

import Foundation

#if canImport(Darwin) || canImport(Glibc)
extension TurnFileChangeTracker {
    func platformDiffStats(before: Data?, after: Data?) async -> DiffStats? {
        let beforeData = before ?? Data()
        let afterData = after ?? Data()

        if beforeData == afterData {
            return nil
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let beforeURL = temporaryDirectory.appendingPathComponent("before")
        let afterURL = temporaryDirectory.appendingPathComponent("after")

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try beforeData.write(to: beforeURL)
            try afterData.write(to: afterURL)
            defer {
                try? fileManager.removeItem(at: temporaryDirectory)
            }

            let result = try await runGitDiff(
                arguments: ["diff", "--no-index", "--numstat", "--", beforeURL.path, afterURL.path]
            )

            guard !result.timedOut,
                  result.exitCode == 0 || result.exitCode == 1,
                  let firstLine = result.stdout.split(whereSeparator: \.isNewline).first else {
                return nil
            }

            let fields = firstLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else {
                return nil
            }

            let additionsField = String(fields[0])
            let deletionsField = String(fields[1])

            if additionsField == "-" || deletionsField == "-" {
                return DiffStats(additions: 0, deletions: 0, isBinary: true)
            }

            return DiffStats(
                additions: Int(additionsField) ?? 0,
                deletions: Int(deletionsField) ?? 0,
                isBinary: false
            )
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            return nil
        }
    }

    func platformGitPatch(
        before: Data?,
        after: Data?,
        displayPath: String,
        existedBefore: Bool,
        existsNow: Bool
    ) async -> String? {
        let beforeData = before ?? Data()
        let afterData = after ?? Data()

        if beforeData == afterData {
            return nil
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let beforeURL = temporaryDirectory.appendingPathComponent("before")
        let afterURL = temporaryDirectory.appendingPathComponent("after")

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            if existedBefore {
                try beforeData.write(to: beforeURL)
            }
            if existsNow {
                try afterData.write(to: afterURL)
            }
            defer {
                try? fileManager.removeItem(at: temporaryDirectory)
            }

            let result = try await runGitDiff(
                arguments: [
                    "diff",
                    "--no-index",
                    "--binary",
                    "--",
                    beforeURL.path,
                    afterURL.path
                ]
            )

            guard !result.timedOut,
                  result.exitCode == 0 || result.exitCode == 1 else {
                return nil
            }

            return rewrittenPatch(
                result.stdout,
                displayPath: displayPath,
                beforePath: existedBefore ? "a/\(displayPath)" : "/dev/null",
                afterPath: existsNow ? "b/\(displayPath)" : "/dev/null"
            )
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            return nil
        }
    }

    private func runGitDiff(arguments: [String]) async throws -> AsyncProcessResult {
        try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: arguments,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 5
        )
    }
}
#endif
