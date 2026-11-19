//
//  FileChangeArtifactDiffTests.swift
//  ZenCODE
//
//  The neutral unified diff and Markdown code block that the terminal's
//  artifacts and the ACP `/changes diff` share.
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

@Suite("File change artifact diff")
struct FileChangeArtifactDiffTests {
    private func artifact(
        status: FileChangeArtifact.Status = .modified,
        old: String? = nil,
        new: String? = nil,
        patch: String? = nil
    ) -> FileChangeArtifact {
        FileChangeArtifact(
            absolutePath: "/work/File.swift",
            displayPath: "File.swift",
            status: status,
            oldText: old,
            newText: new,
            patch: patch
        )
    }

    @Test
    func completeSnapshotsBecomeOneHunkWithContext() {
        let diff = FileChangeArtifactDiff.unifiedDiff(
            for: artifact(old: "a\nb\nc\n", new: "a\nB\nc\n"),
            scope: .changedLines(contextLines: 3)
        )
        #expect(diff == "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c")
    }

    @Test
    func changedLinesScopeLimitsTheContextAndFullFileKeepsEverything() {
        let old = (1...10).map { "l\($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "l5\n", with: "L5\n")
        let modified = artifact(old: old, new: new)

        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: modified, scope: .changedLines(contextLines: 1)
        ) == "@@ -4,3 +4,3 @@\n l4\n-l5\n+L5\n l6")
        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: modified, scope: .changedLines(contextLines: 0)
        ) == "@@ -5,1 +5,1 @@\n-l5\n+L5")

        let full = FileChangeArtifactDiff.unifiedDiff(for: modified, scope: .fullFile)
        #expect(full?.hasPrefix("@@ -1,10 +1,10 @@\n l1\n") == true)
        #expect(full?.hasSuffix(" l10") == true)
    }

    @Test
    func onlyAnAddedOrDeletedStatusEstablishesTheAbsentSide() {
        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: artifact(status: .added, new: "x\n"), scope: .fullFile
        ) == "@@ -0,0 +1,1 @@\n+x")
        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: artifact(status: .deleted, old: "x\n"), scope: .fullFile
        ) == "@@ -1,1 +0,0 @@\n-x")
        // A modification with one side only is not a file against an empty one.
        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: artifact(status: .modified, old: "x\n"), scope: .fullFile
        ) == nil)
        // Nothing changed: nothing to show.
        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: artifact(old: "same\n", new: "same\n"), scope: .fullFile
        ) == nil)
    }

    @Test
    func aCapturedPatchStaysAuthoritativeWithoutCompleteSnapshots() {
        let patch = "diff --git a/File.swift b/File.swift\n--- a/File.swift\n+++ b/File.swift\n@@ -1 +1 @@\n-a\n+b\n"
        // The patch is returned as the artifacts carry it, without the blank
        // edges the presentation never showed.
        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: artifact(old: "a\n", patch: patch), scope: .fullFile
        ) == patch.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(FileChangeArtifactDiff.unifiedDiff(
            for: artifact(patch: "  \n"), scope: .fullFile
        ) == nil)
    }

    @Test
    func theCodeBlockCarriesTheTextWithoutAnExtraBlankLine() {
        #expect(FileChangeArtifactDiff.markdownCodeBlock("-a\n+b\n", language: "diff")
            == ["```diff", "-a", "+b", "```"])
        #expect(FileChangeArtifactDiff.markdownCodeBlock("-a\r\n+b", language: nil)
            == ["```", "-a", "+b", "```"])
    }

    @Test
    func theFenceOutgrowsAnyRunOfBackticksInTheText() {
        let block = FileChangeArtifactDiff.markdownCodeBlock("+```swift\n+let a = 1\n+```\n", language: "diff")
        #expect(block == ["````diff", "+```swift", "+let a = 1", "+```", "````"])
    }
}
