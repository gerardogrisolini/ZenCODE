//
//  TurnFileChangeTrackerDiffTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

#if canImport(Darwin) || canImport(Glibc)
/// Exact line counts, binary detection, and patches produced by the single
/// `git diff --no-index --numstat --binary` run per changed file.
@Suite(.serialized)
struct TurnFileChangeTrackerDiffTests {
    @Test
    func summaryReportsExactCountsAndPatchesForModifiedAddedDeletedAndBinaryFiles() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turn-file-change-diff-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        try Data("a\nb\nc\n".utf8).write(to: url("modified.txt"))
        try Data("end".utf8).write(to: url("no-newline.txt"))
        try Data("x\ny\nz\n".utf8).write(to: url("deleted.txt"))
        try Data([0, 1]).write(to: url("binary-modified.dat"))

        let tracker = TurnFileChangeTracker(baseDirectoryURL: directory)
        let names = [
            "modified.txt", "no-newline.txt", "added.txt", "deleted.txt",
            "binary-added.dat", "binary-modified.dat"
        ]
        for name in names {
            await tracker.captureBaselineIfNeeded(
                for: ToolRequest(name: "local.writeFile", arguments: ["path": .string(name)])
            )
        }

        try Data("a\nB\nc\nd\n".utf8).write(to: url("modified.txt"))
        try Data("end\nmore".utf8).write(to: url("no-newline.txt"))
        try Data("one\ntwo\n".utf8).write(to: url("added.txt"))
        try FileManager.default.removeItem(at: url("deleted.txt"))
        try Data([0, 1, 2, 3]).write(to: url("binary-added.dat"))
        try Data([0, 2, 3]).write(to: url("binary-modified.dat"))

        let summary = try #require(await tracker.makeSummary())
        let entries = Dictionary(uniqueKeysWithValues: summary.entries.map { ($0.path, $0) })
        #expect(Set(entries.keys) == Set(names))

        let modified = try #require(entries["modified.txt"])
        #expect(modified.status == .modified)
        #expect(modified.additions == 2 && modified.deletions == 1 && !modified.isBinary)
        let modifiedPatch = try #require(modified.patch)
        #expect(modifiedPatch.hasPrefix("diff --git a/modified.txt b/modified.txt\n"))
        #expect(modifiedPatch.contains(
            "--- a/modified.txt\n+++ b/modified.txt\n@@ -1,3 +1,4 @@\n a\n-b\n+B\n c\n+d\n"
        ))

        let noNewline = try #require(entries["no-newline.txt"])
        #expect(noNewline.additions == 2 && noNewline.deletions == 1 && !noNewline.isBinary)
        #expect(noNewline.patch?.contains("\\ No newline at end of file") == true)

        let added = try #require(entries["added.txt"])
        #expect(added.status == .added)
        #expect(added.additions == 2 && added.deletions == 0 && !added.isBinary)
        let addedPatch = try #require(added.patch)
        #expect(addedPatch.hasPrefix("diff --git a/added.txt b/added.txt\nnew file mode "))
        #expect(addedPatch.contains("--- /dev/null\n+++ b/added.txt\n@@ -0,0 +1,2 @@\n+one\n+two\n"))

        let deleted = try #require(entries["deleted.txt"])
        #expect(deleted.status == .deleted)
        #expect(deleted.additions == 0 && deleted.deletions == 3 && !deleted.isBinary)
        let deletedPatch = try #require(deleted.patch)
        #expect(deletedPatch.hasPrefix("diff --git a/deleted.txt b/deleted.txt\ndeleted file mode "))
        #expect(deletedPatch.contains("--- a/deleted.txt\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-x\n-y\n-z\n"))

        let binaryAdded = try #require(entries["binary-added.dat"])
        #expect(binaryAdded.status == .added)
        #expect(binaryAdded.isBinary && binaryAdded.additions == 0 && binaryAdded.deletions == 0)
        let binaryAddedPatch = try #require(binaryAdded.patch)
        #expect(binaryAddedPatch.hasPrefix("diff --git a/binary-added.dat b/binary-added.dat\nnew file mode "))
        #expect(binaryAddedPatch.contains("\nGIT binary patch\n"))

        let binaryModified = try #require(entries["binary-modified.dat"])
        #expect(binaryModified.status == .modified)
        #expect(binaryModified.isBinary && binaryModified.additions == 0 && binaryModified.deletions == 0)
        let binaryModifiedPatch = try #require(binaryModified.patch)
        #expect(binaryModifiedPatch.hasPrefix("diff --git a/binary-modified.dat b/binary-modified.dat\n"))
        #expect(binaryModifiedPatch.contains("\nGIT binary patch\n"))

        // Temporary diff inputs never leak into the published patches.
        for entry in summary.entries {
            #expect(entry.patch?.contains(NSTemporaryDirectory()) == false)
            #expect(entry.patch?.contains(" => ") == false)
        }
    }

    @Test
    func numstatAndPatchOutputSplitsAtTheSeparatorLine() {
        let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\r\n+b\r\n"
        let split = TurnFileChangeTracker.splitNumstatAndPatch("1\t1\t{before => after}\n\n" + patch)
        #expect(split.numstat == "1\t1\t{before => after}")
        #expect(split.patch == patch)
        #expect(TurnFileChangeTracker.splitNumstatAndPatch("").numstat.isEmpty)
        #expect(TurnFileChangeTracker.splitNumstatAndPatch("").patch.isEmpty)

        let stats = TurnFileChangeTracker.diffStats(fromNumstat: split.numstat)
        #expect(stats?.additions == 1 && stats?.deletions == 1 && stats?.isBinary == false)
        #expect(TurnFileChangeTracker.diffStats(fromNumstat: "-\t-\tfile")?.isBinary == true)
        #expect(TurnFileChangeTracker.diffStats(fromNumstat: "") == nil)
    }
}
#endif
