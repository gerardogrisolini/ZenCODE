import Foundation
import Testing
import LocalToolsSupport

@Suite
struct PatchFileHeadersTests {
    /// Removing the SQL comment `-- old comment` and adding `++ new counter`
    /// yields lines that look exactly like file headers inside a valid hunk.
    private static let sqlLines = [
        "diff --git a/schema.sql b/schema.sql",
        "index 1111111..2222222 100644",
        "--- a/schema.sql",
        "+++ b/schema.sql",
        "@@ -1,3 +1,3 @@",
        " SELECT 1;",
        "--- old comment",
        "+++ new counter",
        " SELECT 2;"
    ]

    private static let sqlPatch = sqlLines.joined(separator: "\n")

    private static func patch(_ lines: [String], separator: String = "\n") -> String {
        lines.joined(separator: separator)
    }

    @Test
    func hunkBodyLinesThatLookLikeHeadersAreIgnoredInGitDiff() {
        let values = PatchFileHeaders.rawPathValues(in: Self.sqlPatch)

        #expect(values == ["a/schema.sql", "b/schema.sql"])
    }

    @Test
    func rawValuesAreReturnedInPayloadOrderWithoutNormalization() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/old.txt\t2024-01-01 10:00:00",
            "+++ /dev/null",
            "@@ -1 +0,0 @@",
            "-gone",
            "*** Delete File:   Sources/Gone.swift  "
        ]))

        #expect(values == [
            "a/old.txt\t2024-01-01 10:00:00",
            "/dev/null",
            "Sources/Gone.swift"
        ])
    }

    @Test
    func multiFilePatchWithoutGitHeadersAndCorrectCountsReportsBothFiles() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@ -1 +1 @@",
            "-a",
            "+b",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ]))

        #expect(values == ["a/one.txt", "b/one.txt", "a/two.txt", "b/two.txt"])
    }

    @Test
    func tooLargeCountsInFirstFileStillRecognizeTheNextFile() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@ -1,9 +1,9 @@",
            "-a",
            "+b",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ]))

        #expect(values == ["a/one.txt", "b/one.txt", "a/two.txt", "b/two.txt"])
    }

    @Test
    func uncountedHunkKeepsHeaderLookalikesAsContentUntilARealHeader() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@",
            " ctx",
            "--- x",
            "+++ y",
            " ctx",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@",
            "-c",
            "+d"
        ]))

        #expect(values == ["a/one.txt", "b/one.txt", "a/two.txt", "b/two.txt"])
    }

    @Test
    func countedHunkEndingExactlyWithHeaderLookalikesTreatsThemAsContent() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@ -1,2 +1,2 @@",
            " ctx",
            "--- x",
            "+++ y",
            "@@ -10 +10 @@",
            "-a",
            "+b"
        ]))

        #expect(values == ["a/one.txt", "b/one.txt"])
    }

    @Test
    func diffGitLineClosesAnyActiveHunk() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "diff --git a/one.txt b/one.txt",
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@",
            " ctx",
            "diff --git a/two.txt b/two.txt",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ]))

        #expect(values == ["a/one.txt", "b/one.txt", "a/two.txt", "b/two.txt"])
    }

    @Test
    func isolatedMarkersAreNeverHeaders() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- lonely old",
            "some text",
            "+++ lonely new",
            "+++ before old",
            "--- after new"
        ]))

        #expect(values.isEmpty)
    }

    @Test
    func backslashAnnotationDoesNotConsumeHunkCounts() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@ -1,3 +1,3 @@",
            "-a",
            "\\ No newline at end of file",
            "+b",
            "--- x",
            "+++ y",
            " z",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ]))

        #expect(values == ["a/one.txt", "b/one.txt", "a/two.txt", "b/two.txt"])
    }

    @Test
    func beginPatchSectionsTreatMarkerLookalikesAsContent() {
        let body = [
            "*** Update File: Sources/schema.sql",
            "@@",
            " SELECT 1;",
            "--- comment",
            "+++ y",
            "@@",
            "--- another",
            "+++ line",
            " SELECT 2;",
            "*** Add File: Sources/new.sql",
            "+--- dashed",
            "--- not a header",
            "+++ not a header either",
            "*** Delete File: Sources/old.sql"
        ]

        let withEnvelope = PatchFileHeaders.rawPathValues(
            in: Self.patch(["*** Begin Patch"] + body + ["*** End Patch"])
        )
        let withoutEnvelope = PatchFileHeaders.rawPathValues(in: Self.patch(body))

        let expected = ["Sources/schema.sql", "Sources/new.sql", "Sources/old.sql"]
        #expect(withEnvelope == expected)
        #expect(withoutEnvelope == expected)
    }

    @Test
    func unifiedHeadersAreRecognizedAgainAfterEndPatch() {
        let values = PatchFileHeaders.rawPathValues(in: Self.patch([
            "*** Begin Patch",
            "*** Update File: a.txt",
            "--- comment",
            "+++ y",
            "*** End Patch",
            "--- a/b.txt",
            "+++ b/b.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ]))

        #expect(values == ["a.txt", "a/b.txt", "b/b.txt"])
    }

    @Test
    func crlfPayloadsBehaveLikeLfPayloads() {
        let crlfSQL = PatchFileHeaders.rawPathValues(
            in: Self.patch(Self.sqlLines, separator: "\r\n") + "\r\n"
        )
        let crlfMultiFile = PatchFileHeaders.rawPathValues(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@ -1,9 +1,9 @@",
            "-a",
            "+b",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ], separator: "\r\n"))
        let crlfSection = PatchFileHeaders.rawPathValues(in: Self.patch([
            "*** Begin Patch",
            "*** Update File: Sources/schema.sql",
            "--- comment",
            "+++ y",
            "*** End Patch"
        ], separator: "\r\n"))

        #expect(crlfSQL == ["a/schema.sql", "b/schema.sql"])
        #expect(crlfMultiFile == ["a/one.txt", "b/one.txt", "a/two.txt", "b/two.txt"])
        #expect(crlfSection == ["Sources/schema.sql"])
    }

    // MARK: - fileHeaderLineIndices

    @Test
    func headerIndicesOfGitDiffExcludeHunkBodyLookalikes() {
        let indices = PatchFileHeaders.fileHeaderLineIndices(in: Self.sqlPatch)

        // Line 2 is the real `--- a/schema.sql`; line 6 is the removed `-- old comment`.
        #expect(indices == [2])
    }

    @Test
    func headerIndicesOfMultiFilePatchPointAtEachOldFileLine() {
        let indices = PatchFileHeaders.fileHeaderLineIndices(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@ -1 +1 @@",
            "-a",
            "+b",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ]))

        #expect(indices == [0, 5])
    }

    @Test
    func headerIndicesOfMultiFileGitDiffWithLookalikesInTheFirstFile() {
        let indices = PatchFileHeaders.fileHeaderLineIndices(in: Self.patch([
            "diff --git a/one.sql b/one.sql",
            "--- a/one.sql",
            "+++ b/one.sql",
            "@@ -1,2 +1,2 @@",
            "--- x",
            "+++ y",
            "diff --git a/two.txt b/two.txt",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-c",
            "+d"
        ]))

        #expect(indices == [1, 7])
    }

    @Test
    func headerIndicesStayAlignedWithTheLineSplitForCrlfPayloads() {
        let lf = PatchFileHeaders.fileHeaderLineIndices(in: Self.sqlPatch)
        let crlf = PatchFileHeaders.fileHeaderLineIndices(
            in: Self.patch(Self.sqlLines, separator: "\r\n") + "\r\n"
        )

        #expect(lf == [2])
        #expect(crlf == lf)
    }

    @Test
    func headerIndicesOfBeginPatchAreEmpty() {
        let indices = PatchFileHeaders.fileHeaderLineIndices(in: Self.patch([
            "*** Begin Patch",
            "*** Update File: Sources/schema.sql",
            "@@",
            " SELECT 1;",
            "--- comment",
            "+++ y",
            "*** Add File: Sources/new.sql",
            "--- not a header",
            "+++ not a header either",
            "*** End Patch"
        ]))

        #expect(indices.isEmpty)
    }

    @Test
    func headerIndicesIgnoreCountedHunkExhaustedByTheLookalikePair() {
        let indices = PatchFileHeaders.fileHeaderLineIndices(in: Self.patch([
            "--- a/one.txt",
            "+++ b/one.txt",
            "@@ -1,2 +1,2 @@",
            " ctx",
            "--- x",
            "+++ y",
            "@@ -10 +10 @@",
            "-a",
            "+b"
        ]))

        #expect(indices == [0])
    }

    @Test
    func headerIndicesOfIsolatedMarkersAreEmpty() {
        let indices = PatchFileHeaders.fileHeaderLineIndices(in: Self.patch([
            "--- lonely old",
            "some text",
            "+++ lonely new",
            "+++ before old",
            "--- after new"
        ]))

        #expect(indices.isEmpty)
    }

    @Test
    func headerIndicesAndRawPathValuesShareTheSameRule() throws {
        let patches = [
            Self.sqlPatch,
            Self.patch([
                "--- a/one.txt",
                "+++ b/one.txt",
                "@@ -1,9 +1,9 @@",
                "-a",
                "+b",
                "--- a/two.txt",
                "+++ b/two.txt",
                "@@ -1 +1 @@",
                "-c",
                "+d"
            ]),
            Self.patch([
                "--- a/one.txt",
                "+++ b/one.txt",
                "@@",
                " ctx",
                "--- x",
                "+++ y",
                " ctx",
                "--- a/two.txt",
                "+++ b/two.txt",
                "@@",
                "-c",
                "+d"
            ])
        ]

        for patch in patches {
            let lines = patch.components(separatedBy: "\n")
            let valuesFromIndices = try PatchFileHeaders.fileHeaderLineIndices(in: patch)
                .sorted()
                .flatMap { index -> [String] in
                    let next = try #require(lines.indices.contains(index + 1) ? index + 1 : nil)
                    return [String(lines[index].dropFirst(4)), String(lines[next].dropFirst(4))]
                }

            #expect(valuesFromIndices == PatchFileHeaders.rawPathValues(in: patch))
        }
    }
}
