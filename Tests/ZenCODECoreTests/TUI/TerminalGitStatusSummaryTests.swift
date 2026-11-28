//
//  TerminalGitStatusSummaryTests.swift
//  ZenCODE
//
//  The working-tree summary of the status bar, shared by the terminal and the
//  macOS app: the parsing of `git diff --numstat` and of the porcelain
//  status, the tools after which it is refreshed, and the summary of a real
//  repository.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalGitStatusSummaryTests {
    @Test("numstat lines count files, additions and deletions; binary files count with no lines")
    func numstatParsing() {
        let output = "3\t1\tSources/a.swift\n-\t-\tAssets/logo.png\n10\t0\tREADME.md\nmalformed line\n\n"
        let summary = TerminalGitStatusSummary.numstatSummary(from: output)
        #expect(summary == TerminalGitStatusSummary(changedFileCount: 3, additions: 13, deletions: 1))
        #expect(TerminalGitStatusSummary.numstatSummary(from: "")
            == TerminalGitStatusSummary(changedFileCount: 0, additions: 0, deletions: 0))
        // A path with a tab stays one file (maxSplits 2).
        #expect(TerminalGitStatusSummary.numstatSummary(from: "1\t2\tweird\tname").changedFileCount == 1)
    }

    @Test("Untracked files are the ?? lines of porcelain v1")
    func untrackedParsing() {
        let output = " M changed.swift\n?? new.swift\n?? dir/other.txt\nA  added.swift\n"
        #expect(TerminalGitStatusSummary.untrackedFileCount(fromPorcelain: output) == 2)
    }

    @Test("File-mutation tools, whitespace around the name ignored")
    func fileMutationTools() {
        #expect(ToolMutationClassifier.isFileMutationTool("local.write"))
        #expect(ToolMutationClassifier.isFileMutationTool(" local.applyPatch "))
        #expect(!ToolMutationClassifier.isFileMutationTool("local.read"))
        #expect(!ToolMutationClassifier.isFileMutationTool("local.exec"))
    }

    @Test("The summary of a real repository; nil outside one")
    func summaryOfARepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-git-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await TerminalGitStatusSummary.read(in: root, timeout: 10) == nil)

        guard try await git(["init", "-q"], in: root) else {
            // No git on this machine: the summary is nil, as above.
            return
        }
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(try await git(["add", "a.txt"], in: root))
        #expect(try await git([
            "-c", "user.name=ZenCODE", "-c", "user.email=zen@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-q", "-m", "init",
        ], in: root))
        #expect(await TerminalGitStatusSummary.read(in: root, timeout: 10)
            == TerminalGitStatusSummary(changedFileCount: 0, additions: 0, deletions: 0))

        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        #expect(await TerminalGitStatusSummary.read(in: root, timeout: 10)
            == TerminalGitStatusSummary(changedFileCount: 2, additions: 2, deletions: 0))
    }

    private func git(_ arguments: [String], in directory: URL) async throws -> Bool {
        let result = try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: arguments,
            workingDirectory: directory,
            timeout: 10
        )
        return result.exitCode == 0
    }
}
