//
//  ZenPromptHistoryAndGitTests.swift
//  ZenAppSessionTests
//

import Foundation
import Testing
import ZenCODECore
@testable import ZenAppSession

@Suite(.serialized)
struct ZenPromptHistoryTests {
    @Test("Recording trims, skips blanks and repeats in a row")
    func recording() {
        var history = ZenPromptHistory()
        history.record("  one ")
        history.record("")
        history.record("one")
        history.record("two")
        history.record("one")
        #expect(history.entries == ["one", "two", "one"])
    }

    @Test("↑ walks back from the newest entry, ↓ walks forward and gives the draft back")
    func navigation() {
        var history = ZenPromptHistory(entries: ["a", "b", "c"])
        #expect(history.recallNext(currentDraft: "draft") == nil)
        #expect(history.recallPrevious(currentDraft: "draft") == "c")
        #expect(history.recallPrevious(currentDraft: "c") == "b")
        #expect(history.recallPrevious(currentDraft: "b") == "a")
        // Nothing older: nothing changes.
        #expect(history.recallPrevious(currentDraft: "a") == nil)
        #expect(history.recallNext(currentDraft: "a") == "b")
        #expect(history.recallNext(currentDraft: "b") == "c")
        #expect(history.recallNext(currentDraft: "c") == "draft")
        #expect(history.index == nil)
        #expect(history.recallNext(currentDraft: "draft") == nil)
    }

    @Test("Editing a recalled entry ends the recall")
    func editingEndsRecall() {
        var history = ZenPromptHistory(entries: ["a", "b"])
        #expect(history.recallPrevious(currentDraft: "") == "b")
        // The operator edited "b": ↓ changes nothing, ↑ starts over from the newest.
        #expect(history.recallNext(currentDraft: "b!") == nil)
        #expect(history.recallPrevious(currentDraft: "b!") == "b")
        #expect(history.recallNext(currentDraft: "b") == "b!")
    }

    @Test("An empty history recalls nothing")
    func emptyHistory() {
        var history = ZenPromptHistory()
        #expect(history.recallPrevious(currentDraft: "x") == nil)
        #expect(history.recallNext(currentDraft: "x") == nil)
    }
}

@Suite(.serialized)
struct ZenGitStatusTests {
    @Test("numstat lines count files, additions and deletions; binary files count with no lines")
    func numstatParsing() {
        let output = "3\t1\tSources/a.swift\n-\t-\tAssets/logo.png\n10\t0\tREADME.md\nmalformed line\n\n"
        let summary = ZenGitStatus.numstatSummary(from: output)
        #expect(summary == TerminalGitStatusSummary(changedFileCount: 3, additions: 13, deletions: 1))
        #expect(ZenGitStatus.numstatSummary(from: "") == .zero)
        // A path with a tab stays one file (maxSplits 2).
        #expect(ZenGitStatus.numstatSummary(from: "1\t2\tweird\tname").changedFileCount == 1)
    }

    @Test("Untracked files are the ?? lines of porcelain v1")
    func untrackedParsing() {
        let output = " M changed.swift\n?? new.swift\n?? dir/other.txt\nA  added.swift\n"
        #expect(ZenGitStatus.untrackedFileCount(fromPorcelain: output) == 2)
    }

    @Test("File-mutation tools are the terminal's")
    func fileMutationTools() {
        #expect(ZenGitStatus.isFileMutationTool("local.writeFile"))
        #expect(ZenGitStatus.isFileMutationTool(" local.applyPatch "))
        #expect(!ZenGitStatus.isFileMutationTool("local.readFile"))
        #expect(!ZenGitStatus.isFileMutationTool("local.exec"))
    }

    @Test("The summary of a real repository; nil outside one")
    func summaryOfARepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await ZenGitStatus.summary(in: root, timeout: 10) == nil)

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
        #expect(await ZenGitStatus.summary(in: root, timeout: 10) == .zero)

        try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        #expect(await ZenGitStatus.summary(in: root, timeout: 10)
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
