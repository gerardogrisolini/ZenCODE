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
        try await runGit(arguments: arguments)
    }

    func runGit(arguments: [String]) async throws -> AsyncProcessResult {
        try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: arguments,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 5
        )
    }

    // MARK: - Worktree reconciliation

    /// Reads and stores the current content of every file that is already dirty
    /// (relative to `HEAD`/index) when the turn begins.
    func captureInitialWorktreeBaseline() async {
        guard let repositoryRoot = await repositoryRootPath() else {
            return
        }

        for relativePath in await gitStatusDirtyRelativePaths(repositoryRoot: repositoryRoot) {
            let absolutePath = URL(fileURLWithPath: repositoryRoot)
                .appendingPathComponent(relativePath)
                .standardizedFileURL
                .path
            guard !initialWorktreeDirtyContents.keys.contains(absolutePath) else {
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                continue
            }
            let content = exists
                ? try? Data(contentsOf: URL(fileURLWithPath: absolutePath))
                : nil
            initialWorktreeDirtyContents[absolutePath] = .some(content)
        }
    }

    /// Adds snapshots for files changed during the turn that were not captured
    /// through per-tool baselines (e.g. changes made by `local.exec`,
    /// sub-agents, or MCP tools). Only runs when the initial worktree baseline
    /// was captured, so changes that predate the turn are never reported.
    func reconcileWorktreeChangesIfNeeded() async {
        guard didCaptureInitialWorktree,
              let repositoryRoot = await repositoryRootPath() else {
            return
        }

        let basePath = baseDirectoryURL.path
        for relativePath in await gitStatusDirtyRelativePaths(repositoryRoot: repositoryRoot) {
            let absolutePath = URL(fileURLWithPath: repositoryRoot)
                .appendingPathComponent(relativePath)
                .standardizedFileURL
                .path
            guard absolutePath == basePath || absolutePath.hasPrefix(basePath + "/") else {
                continue
            }
            guard snapshotsByPath[absolutePath] == nil else {
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                continue
            }

            let beforeData: Data?
            if let storedContent = initialWorktreeDirtyContents[absolutePath] {
                // File was already dirty at turn start: baseline is its content then.
                beforeData = storedContent
            } else {
                // File was clean at turn start: baseline is the committed HEAD content.
                beforeData = await gitHeadContent(
                    repositoryRoot: repositoryRoot,
                    relativePath: relativePath
                )
            }

            snapshotsByPath[absolutePath] = Snapshot(
                absolutePath: absolutePath,
                displayPath: displayPath(for: absolutePath),
                beforeData: beforeData,
                existedInitially: beforeData != nil
            )
        }
    }

    func repositoryRootPath() async -> String? {
        guard let result = try? await runGit(
            arguments: ["-C", baseDirectoryURL.path, "rev-parse", "--show-toplevel"]
        ),
            !result.timedOut,
            result.exitCode == 0 else {
            return nil
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func gitStatusDirtyRelativePaths(repositoryRoot: String) async -> [String] {
        guard let result = try? await runGit(
            arguments: [
                "-C", repositoryRoot,
                "status", "--porcelain", "-z",
                "--no-renames", "--untracked-files=all"
            ]
        ),
            !result.timedOut,
            result.exitCode == 0 else {
            return []
        }

        var relativePaths: [String] = []
        for token in result.stdoutData.split(separator: 0, omittingEmptySubsequences: true) {
            // Porcelain v1 records are "XY <path>": two status columns, one
            // separator space, then the repository-root-relative path.
            guard token.count > 3 else {
                continue
            }
            let pathBytes = token.dropFirst(3)
            let relativePath = String(decoding: pathBytes, as: UTF8.self)
            if !relativePath.isEmpty {
                relativePaths.append(relativePath)
            }
        }
        return relativePaths
    }

    func gitHeadContent(repositoryRoot: String, relativePath: String) async -> Data? {
        guard let result = try? await runGit(
            arguments: ["-C", repositoryRoot, "show", "HEAD:\(relativePath)"]
        ),
            !result.timedOut,
            result.exitCode == 0 else {
            return nil
        }
        return result.stdoutData
    }
}
#endif
