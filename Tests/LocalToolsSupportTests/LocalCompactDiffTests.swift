import Foundation
import Testing
import ToolCore
@testable import LocalToolsSupport

@Suite
struct LocalCompactDiffTests {
    private func diff(_ old: String, _ new: String, budget: Int = OperationFileChangeRecorder.maximumTextBytes) throws -> OperationFileChange.CompactDiff {
        try LocalCompactDiff.make(old: old, new: new, maximumBytes: budget)
    }

    @Test func separatedEditsKeepOnlyThreeContextLinesAndAccurateOffsets() throws {
        let old = (1...100).map { "line \($0)\n" }.joined()
        let new = old.replacingOccurrences(of: "line 20\n", with: "changed 20\n")
            .replacingOccurrences(of: "line 80\n", with: "changed 80\n")
        let result = try diff(old, new)
        #expect(result.additions == 2)
        #expect(result.deletions == 2)
        #expect(result.patch == """
        @@ -17,7 +17,7 @@
         line 17
         line 18
         line 19
        -line 20
        +changed 20
         line 21
         line 22
         line 23
        @@ -77,7 +77,7 @@
         line 77
         line 78
         line 79
        -line 80
        +changed 80
         line 81
         line 82
         line 83

        """)
    }

    @Test func boundaryHunksAndRepeatedLinesHaveExactCounts() throws {
        #expect(try diff("", "a\n").patch == "@@ -0,0 +1,1 @@\n+a\n")
        #expect(try diff("a\n", "").patch == "@@ -1,1 +0,0 @@\n-a\n")
        let old = String(repeating: "same\n", count: 100)
        let result = try diff(old, "first\n" + old + "last\n")
        #expect(result.additions == 2)
        #expect(result.deletions == 0)
        #expect(result.patch.hasPrefix("@@ -1,3 +1,4 @@\n+first\n"))
        #expect(result.patch.contains("@@ -98,3 +99,4 @@\n"))
        #expect(result.patch.hasSuffix("+last\n"))
        #expect(try diff(old, old) == .init(patch: "", additions: 0, deletions: 0))
        #expect(try diff("", "") == .init(patch: "", additions: 0, deletions: 0))
    }

    @Test func nearbyEditsMergeAndInsertionOffsetsAccountForEarlierHunks() throws {
        let old = (1...30).map { "line \($0)\n" }.joined()
        let new = "inserted\n" + old.replacingOccurrences(of: "line 15\n", with: "changed\n")
            .replacingOccurrences(of: "line 18\n", with: "also changed\n")
        let result = try diff(old, new)
        #expect(result.additions == 3)
        #expect(result.deletions == 2)
        #expect(result.patch.components(separatedBy: "@@ -").count - 1 == 2)
        #expect(result.patch.contains("@@ -12,10 +13,10 @@"))
    }

    @Test func byteExactUnicodeCRLFAndFinalNewlineChangesRemainVisible() throws {
        let newline = try diff("last\n", "last")
        #expect(newline.patch == "@@ -1,1 +1,1 @@\n-last\n+last\n\\ No newline at end of file\n")
        #expect(newline.additions == 1 && newline.deletions == 1)
        let unicode = try diff("caf\u{e9}\n", "cafe\u{301}\n")
        #expect(unicode.additions == 1 && unicode.deletions == 1)
        #expect(unicode.patch.utf8.contains(0xc3))
        #expect(unicode.patch.utf8.contains(0xcc))
        let crlf = try diff("a\r\nb\r\n", "a\r\nc\r\n")
        #expect(crlf.patch.contains(" a\r\n-b\r\n+c\r\n"))
        #expect(try diff("a\r\n", "a\n").additions == 1)
    }

    @Test func outputBudgetIsByteBasedAndNeverReturnsPartialHunks() throws {
        let result = try diff("before\n", "界 after\n")
        #expect(try diff("before\n", "界 after\n", budget: result.patch.utf8.count) == result)
        #expect(throws: LocalCompactDiff.Failure.byteLimit) {
            try diff("before\n", "界 after\n", budget: result.patch.utf8.count - 1)
        }
        let line = String(repeating: "x", count: OperationFileChangeRecorder.maximumTextBytes + 1)
        #expect(throws: LocalCompactDiff.Failure.byteLimit) { try diff(line, line + "y") }
    }

    @Test func inputLineCountAndSearchBudgetsFailClosed() {
        let huge = String(repeating: "x", count: OperationFileChangeRecorder.maximumSnapshotBytes + 1)
        #expect(throws: LocalCompactDiff.Failure.byteLimit) { try diff(huge, huge) }
        let dense = String(repeating: "\n", count: LocalCompactDiff.maximumLines + 1)
        #expect(throws: LocalCompactDiff.Failure.workLimit) { try diff(dense, dense) }
        let old = (0..<300).map { "old \($0)\n" }.joined()
        let new = (0..<300).map { "new \($0)\n" }.joined()
        #expect(throws: LocalCompactDiff.Failure.workLimit) { try diff(old, new) }
        // Few very long unequal lines exhaust comparison bytes before distance.
        let long = String(repeating: "x", count: 8 * 1024)
        let costlyOld = (0..<100).map { "a\($0)\(long)\n" }.joined()
        let costlyNew = (0..<100).map { "b\($0)\(long)\n" }.joined()
        #expect(throws: LocalCompactDiff.Failure.workLimit) { try diff(costlyOld, costlyNew) }
    }
}
